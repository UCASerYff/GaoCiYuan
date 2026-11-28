"""Require the supported x64 renderer before opening the desktop application."""

from __future__ import annotations

import ctypes
import sys
from importlib.util import find_spec
from pathlib import Path

from gaociyuan.errors import AppError
from gaociyuan.version import APP_NAME, MARKETING_VERSION

EDGE_RENDERER = 'edgechromium'
LOADER = Path('lib', 'runtimes', 'win-x64', 'native', 'WebView2Loader.dll')
RUNTIME_ERROR = '无法启动搞词元。请安装或修复 Microsoft Edge WebView2 Evergreen Runtime（x64），然后重新打开。'
DEPENDENCY_ERROR = '搞词元的 WebView2 界面依赖缺失或无法加载。请重新安装完整的 Windows 安装包。'
OTHER_BACKENDS = ('android', 'cef', 'cocoa', 'gtk', 'mshtml', 'qt')


def installed_webview2_version(loader_path: Path) -> str:
    try:
        loader = ctypes.WinDLL(str(loader_path))
        probe = loader.GetAvailableCoreWebView2BrowserVersionString
        probe.argtypes = (ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_void_p))
        probe.restype = ctypes.c_long
        release = ctypes.WinDLL('ole32').CoTaskMemFree
        release.argtypes = (ctypes.c_void_p,)
        release.restype = None
    except (OSError, AttributeError):
        raise AppError(DEPENDENCY_ERROR) from None

    version = ctypes.c_void_p()
    try:
        if probe(None, ctypes.byref(version)) < 0 or not version.value:
            raise AppError(RUNTIME_ERROR)
        value = ctypes.wstring_at(version).strip()
        if not value or value == '0.0.0.0':
            raise AppError(RUNTIME_ERROR)
        return value
    finally:
        if version.value:
            release(version)


def require_webview2() -> None:
    if getattr(sys, 'frozen', False):
        package = Path(sys._MEIPASS) / 'webview'
    else:
        spec = find_spec('webview')
        if spec is None or spec.origin is None:
            raise AppError(DEPENDENCY_ERROR)
        package = Path(spec.origin).parent
    installed_webview2_version(package / LOADER)

    # WinForms imports MSHTML when its own detection fails. Block all alternative
    # backends before initialization even when running with unbundled dependencies.
    for backend in OTHER_BACKENDS:
        name = 'webview.platforms.' + backend
        if sys.modules.get(name) is not None:
            raise AppError(RUNTIME_ERROR)
        sys.modules[name] = None
    try:
        from webview.guilib import initialize

        renderer = initialize(EDGE_RENDERER)
    except Exception:
        raise AppError(RUNTIME_ERROR) from None
    if getattr(renderer, 'renderer', None) != EDGE_RENDERER:
        raise AppError(RUNTIME_ERROR)


def startup_error(message: str) -> None:
    ctypes.windll.user32.MessageBoxW(None, message, f'{APP_NAME} V{MARKETING_VERSION}', 0x10)
