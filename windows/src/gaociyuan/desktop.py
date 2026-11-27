"""WinForms/WebView2 host, notification area, and separate topmost quota rail."""

from __future__ import annotations

import ctypes
import json
import os
import sys
import threading
import winreg
from ctypes import wintypes
from pathlib import Path

import webview
from PIL import Image, ImageDraw
from pystray import Menu, MenuItem
from pystray._win32 import Icon

from gaociyuan.errors import AppError
from gaociyuan.resources import brand_dir
from gaociyuan.routes import app_fragment
from gaociyuan.version import APP_NAME, MARKETING_VERSION

APP_ID = 'com.gaoseries.GaoCiYuan'
APP_MUTEX = 'Local\\com.gaoseries.GaoCiYuan.desktop'
RUNTIME_KEY = r'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
UINT = wintypes.UINT
HWND = wintypes.HWND
RECT = wintypes.RECT


class MONITORINFO(ctypes.Structure):
    _fields_ = [('cbSize', wintypes.DWORD), ('rcMonitor', RECT), ('rcWork', RECT), ('dwFlags', wintypes.DWORD)]


class DesktopTray(Icon):
    def __init__(self, desktop, image, menu):
        self.desktop = desktop
        super().__init__(APP_ID, icon=image, title=APP_NAME, menu=menu)

    def _on_notify(self, wparam, lparam):
        if lparam == 0x405:  # NIN_BALLOONUSERCLICK
            self.desktop.open_main(self.desktop.notification_route)
        else:
            super()._on_notify(wparam, lparam)


class Desktop:
    def __init__(self, server, instance, initial_route: str, hidden: bool):
        self.server = server
        self.store = server.store
        self.instance = instance
        self.hidden = hidden
        self.exiting = False
        self.ready = False
        self.panel_ready = False
        self.tray_ready = False
        self.panel_visible = False
        self.notification_route = '#overview'
        self._requested_size = (74, 106, 0, 0)
        self._panel_state = None
        self._floating_detail_side = None
        self._previous_dark = None
        self._last_monitor = None
        self._tray_warning = None
        self._drag_rect = None

        # Configure before WinForms creates its first HWND.
        self.user32 = ctypes.windll.user32
        self.user32.GetForegroundWindow.restype = HWND
        self.user32.MonitorFromPoint.argtypes = (wintypes.POINT, wintypes.DWORD)
        self.user32.MonitorFromPoint.restype = wintypes.HMONITOR
        self.user32.MonitorFromWindow.argtypes = (HWND, wintypes.DWORD)
        self.user32.MonitorFromWindow.restype = wintypes.HMONITOR
        self.user32.GetMonitorInfoW.argtypes = (wintypes.HMONITOR, ctypes.POINTER(MONITORINFO))
        self.user32.SetWindowPos.argtypes = (HWND, HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, UINT)
        self.user32.GetWindowRect.argtypes = (HWND, ctypes.POINTER(RECT))
        self.user32.GetDpiForWindow.argtypes = (HWND,)
        try:
            self.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # Per-monitor v2
        except AttributeError:
            pass
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(APP_ID)
        kernel32 = ctypes.windll.kernel32
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        self.mutex = kernel32.CreateMutexW(None, False, APP_MUTEX) if not hidden else None

        background = '#171c1a' if self.dark else '#f5f5f0'
        webview.settings['ALLOW_DOWNLOADS'] = True
        webview.settings['OPEN_EXTERNAL_LINKS_IN_BROWSER'] = True
        self.main = webview.create_window(f'{APP_NAME} V{MARKETING_VERSION}', server.url + initial_route,
                                          width=1160, height=760, min_size=(760, 560),
                                          hidden=hidden, text_select=True, background_color=background)
        self.panel = webview.create_window(f'{APP_NAME} · 悬浮窗', server.url + 'panel',
                                           width=74, height=106, min_size=(1, 1),
                                           hidden=True, frameless=True, focus=False, easy_drag=False,
                                           on_top=True, transparent=True, js_api=PanelBridge(self),
                                           background_color=background)
        self.main.events.closing += self._close_main
        self.main.events.loaded += self._main_loaded
        self.panel.events.loaded += self._panel_loaded
        self.tray_image = Image.open(brand_dir() / 'GaoCiYuanIcon.png').convert('RGBA').resize((64, 64), Image.Resampling.LANCZOS)
        self.tray = DesktopTray(self, self.tray_image, Menu(
            MenuItem('打开搞词元', lambda: self.open_main(), default=True),
            MenuItem('悬浮窗', self.toggle_panel, checked=lambda _: bool(self.store.settings['panelFloating'])),
            MenuItem('设置', lambda: self.open_main('#settings')),
            Menu.SEPARATOR,
            MenuItem('退出搞词元', self.server.shutdown_requested.set),
        ))
        self.store.notify = self.notify
        server.native = self

    @property
    def cli_path(self) -> str | None:
        if not getattr(sys, 'frozen', False):
            return None
        path = Path(sys.executable).with_name('GaoCiYuan-cli.exe')
        return str(path) if path.is_file() else None

    @property
    def dark(self) -> bool:
        appearance = self.store.settings['appearance']
        if appearance != 'system':
            return appearance == 'dark'
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') as key:
                return winreg.QueryValueEx(key, 'AppsUseLightTheme')[0] == 0
        except OSError:
            return False

    @staticmethod
    def handle(window):
        return window.native.Handle.ToInt64() if window.native is not None else 0

    def start(self) -> None:
        # A dedicated profile avoids inheriting browser cookies or user browser extensions.
        profile = self.store.directory / 'webview2'
        profile.mkdir(parents=True, exist_ok=True)
        try:
            webview.start(self._run, gui='edgechromium', private_mode=False, storage_path=str(profile))
        finally:
            if self.tray_ready:
                self.tray.stop()
            if self.mutex:
                ctypes.windll.kernel32.CloseHandle(self.mutex)

    def _run(self) -> None:
        if not self.hidden:
            self.tray.run_detached(setup=self._show_tray)
        while not self.server.shutdown_requested.wait(.25):
            fragment = self.instance.read_route()
            if fragment:
                self.open_main(fragment)
            if self.ready:
                self._update_titlebar()
            if self.panel_ready:
                self._sync_panel()
            if self.tray_ready:
                self._tray_status()
        self.exiting = True
        self.panel.destroy()
        self.main.destroy()

    def _show_tray(self, icon) -> None:
        icon.visible = True
        self.tray_ready = True

    def _main_loaded(self) -> None:
        self.ready = True
        self._update_titlebar()

    def _panel_loaded(self) -> None:
        self.panel_ready = True
        self._floating_detail_side = None
        user32 = self.user32
        user32.GetWindowLongW.argtypes = (HWND, ctypes.c_int)
        user32.SetWindowLongW.argtypes = (HWND, ctypes.c_int, ctypes.c_long)
        hwnd = self.handle(self.panel)
        style = user32.GetWindowLongW(hwnd, -20)
        user32.SetWindowLongW(hwnd, -20, (style | 0x80 | 0x08000000) & ~0x00040000)

    def _close_main(self):
        if self.exiting:
            return True
        if not self.tray_ready:
            self.server.shutdown_requested.set()
            return False
        # Closing this view keeps the requested tray refreshes and quota rail running.
        threading.Thread(target=self.main.hide, daemon=True).start()
        return False

    def open_main(self, fragment: str | None = None) -> None:
        if self.exiting:
            return
        if fragment:
            if self.ready:
                self.main.run_js(f'window.location.hash = {json.dumps(fragment)}')
            else:
                self.main.load_url(self.server.url + fragment)
        if self.hidden:
            return
        self.main.show()
        handle = self.handle(self.main)
        if handle:
            if self.user32.IsIconic(HWND(handle)):
                self.user32.ShowWindow(HWND(handle), 9)
            self.user32.SetForegroundWindow(HWND(handle))

    def choose(self, kind: str) -> str | None:
        if kind == 'snapshot':
            result = self.main.create_file_dialog(webview.FileDialog.OPEN, file_types=('JSON (*.json)',))
        else:
            result = self.main.create_file_dialog(webview.FileDialog.FOLDER)
        return result[0] if result else None

    def notify(self, account: dict, message: str) -> None:
        if not self.tray_ready:
            return
        try:
            self.notification_route = app_fragment('overview', account['id'])
        except ValueError:
            self.notification_route = '#overview'
        try:
            self.tray.notify(message[:255], f'{APP_NAME} · {account["name"]}'[:63])
        except OSError:
            pass

    def _tray_status(self) -> None:
        from gaociyuan.rings import attention

        with self.server.lock:
            threshold = self.store.library['warningThreshold']
            warning = any(attention(item, threshold, self.store.now()) for item in self.store.library['accounts'])
        if warning == self._tray_warning:
            return
        self._tray_warning = warning
        image = self.tray_image.copy()
        if warning:
            ImageDraw.Draw(image).ellipse((45, 3, 62, 20), fill='#ee7762', outline='white', width=2)
        self.tray.icon = image

    def toggle_panel(self) -> None:
        with self.server.lock:
            try:
                self.store.update_settings({'panelFloating': not self.store.settings['panelFloating']})
            except AppError:
                return
        self.tray.update_menu()

    def _update_titlebar(self) -> None:
        dark = self.dark
        if dark == self._previous_dark:
            return
        self._previous_dark = dark
        value = ctypes.c_int(int(dark))
        window = HWND(self.handle(self.main))
        dwm = ctypes.windll.dwmapi.DwmSetWindowAttribute
        if dwm(window, 20, ctypes.byref(value), ctypes.sizeof(value)):
            dwm(window, 19, ctypes.byref(value), ctypes.sizeof(value))

    def size_panel(self, payload: dict) -> None:
        values = [payload.get(key, 0) for key in ('width', 'height', 'detailWidth', 'detailHeight')]
        if any(type(value) is not int or not 0 <= value <= 1500 for value in values) or any(value < 36 for value in values[:2]):
            raise AppError('悬浮窗尺寸无效。')
        self._requested_size = tuple(values)
        if self.panel_ready:
            self._sync_panel()

    def _monitor(self):
        point = wintypes.POINT()
        self.user32.GetCursorPos(ctypes.byref(point))
        cursor_monitor = self.user32.MonitorFromPoint(point, 2)
        if self._last_monitor is None or self.store.settings['panelFollowDisplay']:
            self._last_monitor = cursor_monitor
        position = self.store.settings.get('panelPosition')
        if not self.store.settings['panelFollowDisplay'] and self.store.settings['panelDock'] == 'floating' and isinstance(position, list) and len(position) == 2 and all(type(value) is int for value in position):
            self._last_monitor = self.user32.MonitorFromPoint(wintypes.POINT(*position), 2)
        info = MONITORINFO()
        info.cbSize = ctypes.sizeof(info)
        if not self.user32.GetMonitorInfoW(self._last_monitor, ctypes.byref(info)):
            self._last_monitor = cursor_monitor
            self.user32.GetMonitorInfoW(self._last_monitor, ctypes.byref(info))
        return info

    def _foreground_fullscreen(self, monitor) -> bool:
        active = self.user32.GetForegroundWindow()
        if not active or active == self.handle(self.panel):
            return False
        rect = RECT()
        self.user32.GetWindowRect(active, ctypes.byref(rect))
        return rect.left <= monitor.left and rect.right >= monitor.right and rect.top <= monitor.top and rect.bottom >= monitor.bottom

    def _sync_panel(self) -> None:
        settings = self.store.settings
        if self.hidden or self.exiting:
            return
        monitor = self._monitor()
        visible = settings['panelFloating'] and not (settings['panelHideFullScreen'] and self._foreground_fullscreen(monitor.rcMonitor))
        if not visible:
            if self.panel_visible:
                self.panel.hide()
                self.panel_visible = False
            return
        if self._drag_rect is not None or not self.handle(self.panel):
            return
        handle = HWND(self.handle(self.panel))
        scale = self.user32.GetDpiForWindow(handle) / 96 or 1
        width, height, detail_width, detail_height = (round(size * scale) for size in self._requested_size)
        dock = settings['panelDock']
        work = monitor.rcWork
        x = work.right - width if dock == 'right' else work.left
        y = work.top + (work.bottom - work.top - height) // 2
        position = settings.get('panelPosition')
        if dock == 'top':
            y = work.top
            width = max(width, detail_width)
            x = work.left + (work.right - work.left - width) // 2
            height += detail_height
        else:
            if dock == 'floating' and isinstance(position, list) and len(position) == 2 and all(type(value) is int for value in position):
                x, y = position
            detail_before_rail = dock == 'right'
            if dock == 'floating':
                x = max(work.left, min(x, work.right - width))
                detail_before_rail = x - work.left > work.right - x - width
                side = 'before' if detail_before_rail else 'after'
                if side != self._floating_detail_side:
                    self._floating_detail_side = side
                    self.panel.run_js(f'document.querySelector("#shell").dataset.detailSide = "{side}"')
            if detail_before_rail:
                x -= detail_width
            width += detail_width
            height = max(height, detail_height)
        width = min(width, work.right - work.left)
        height = min(height, work.bottom - work.top)
        x = max(work.left, min(x, work.right - width))
        y = max(work.top, min(y, work.bottom - height))
        state = (x, y, width, height)
        if state != self._panel_state or not self.panel_visible:
            self.user32.SetWindowPos(handle, HWND(-1), x, y, width, height, 0x0010 | 0x0040)
            self._panel_state = state
            self.panel_visible = True

    def end_drag(self) -> None:
        if self._drag_rect is None:
            return
        self._drag_rect = None
        rect = RECT()
        hwnd = HWND(self.handle(self.panel))
        self.user32.GetWindowRect(hwnd, ctypes.byref(rect))
        self._last_monitor = self.user32.MonitorFromWindow(hwnd, 2)
        info = self._monitor()
        work = info.rcWork
        threshold = 25 * self.user32.GetDpiForWindow(hwnd) / 96
        distances = {'left': abs(rect.left - work.left), 'right': abs(rect.right - work.right), 'top': abs(rect.top - work.top)}
        edge = min(distances, key=distances.get)
        with self.server.lock:
            self.store.update_settings({'panelDock': edge if distances[edge] <= threshold else 'floating', 'panelPosition': [rect.left, rect.top]})
        self._panel_state = None


class PanelBridge:
    def __init__(self, desktop):
        self._desktop = desktop

    def drag_start(self):
        desk = self._desktop
        point, rect = wintypes.POINT(), RECT()
        desk.user32.GetCursorPos(ctypes.byref(point))
        desk.user32.GetWindowRect(HWND(desk.handle(desk.panel)), ctypes.byref(rect))
        desk._drag_rect = (point.x - rect.left, point.y - rect.top)

    def drag_move(self):
        desk = self._desktop
        if desk._drag_rect is None:
            return
        point = wintypes.POINT()
        desk.user32.GetCursorPos(ctypes.byref(point))
        x, y = desk._drag_rect
        desk.user32.SetWindowPos(HWND(desk.handle(desk.panel)), None, point.x - x, point.y - y, 0, 0, 0x0001 | 0x0004 | 0x0010)

    def drag_end(self):
        self._desktop.end_drag()


def runtime_available() -> bool:
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for view in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
            try:
                with winreg.OpenKey(hive, RUNTIME_KEY, 0, winreg.KEY_READ | view) as key:
                    if winreg.QueryValueEx(key, 'pv')[0] not in ('', '0.0.0.0'):
                        return True
            except OSError:
                continue
    return False


def startup_error(message: str) -> None:
    ctypes.windll.user32.MessageBoxW(None, message, f'{APP_NAME} V{MARKETING_VERSION}', 0x10)
