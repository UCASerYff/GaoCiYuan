import ctypes
import json
import sys
import threading
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaociyuan.cli import main
from gaociyuan.store import TokenStore
from gaociyuan.web import serve


def test_console_help_does_not_initialize_a_profile(tmp_path, capsys):
    profile = tmp_path / 'console-profile'
    assert main(['--data-dir', str(profile)], console=True) == 0
    assert 'usage:' in capsys.readouterr().out
    assert not profile.exists()


def test_shutdown_drains_admitted_setting_write_and_rejects_new_write(tmp_path):
    store = TokenStore(tmp_path)
    start = threading.Event()
    release = threading.Event()
    drained = threading.Event()
    update_settings = store.update_settings

    def delayed_write(payload):
        start.set()
        assert release.wait(5)
        return update_settings(payload)

    store.update_settings = delayed_write
    server = serve(store, open_browser=False, start_timer=False)

    def post_settings(appearance):
        request = Request(server.url + 'api/settings', json.dumps({'appearance': appearance}).encode(),
                          {'X-Gao-Token': server.token, 'Content-Type': 'application/json'})
        with urlopen(request, timeout=5) as response:
            return json.load(response)

    def drain():
        server.drain_work()
        drained.set()

    results = []
    writer = threading.Thread(target=lambda: results.append(post_settings('dark')), daemon=True)
    closer = threading.Thread(target=drain, daemon=True)
    writer.start()
    try:
        assert start.wait(5)
        server.request_shutdown()
        closer.start()
        with pytest.raises(HTTPError) as rejected:
            post_settings('light')
        assert rejected.value.code == 503
        assert not drained.is_set()
        release.set()
        assert drained.wait(5)
        writer.join(5)
        assert results[0]['ok']
        assert TokenStore(tmp_path).settings['appearance'] == 'dark'
    finally:
        release.set()
        server.shutdown()
        server.server_close()


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows data-folder activation')
def test_plain_windows_activation_keeps_the_current_route(tmp_path):
    from gaociyuan.instance import Instance

    instance = Instance(tmp_path)
    try:
        instance.activate('')
        assert instance.read_route() == ''
        assert instance.read_route() is None
        instance.activate('#settings')
        assert instance.read_route() == '#settings'
    finally:
        instance.close()


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows native window lifecycle')
def test_native_quit_waits_for_save_and_cancel_retains_the_host():
    from gaociyuan.desktop import Desktop

    calls = []
    states = iter([
        {'dirty': True, 'pending': True}, {'dirty': True, 'pending': False},
        {'dirty': True, 'pending': False}, {'dirty': True, 'pending': True},
        {'dirty': False, 'pending': False},
    ])
    answers = iter([2, 1])
    desktop = object.__new__(Desktop)
    desktop.ready = True
    desktop._quit_requested = threading.Event()
    desktop._quit_confirmed = False
    desktop.main = SimpleNamespace(run_js=lambda _: next(states))
    desktop.open_main = lambda: calls.append('open')
    desktop.handle = lambda _: 0
    desktop.user32 = SimpleNamespace(MessageBoxW=lambda *_: next(answers))
    desktop.server = SimpleNamespace(request_shutdown=lambda: calls.append('shutdown'))

    desktop.request_quit()
    assert not desktop._quit_if_ready() and calls == []
    assert not desktop._quit_if_ready() and calls == ['open']
    assert not desktop._quit_requested.is_set()

    desktop.request_quit()
    assert not desktop._quit_if_ready() and calls == ['open', 'open']
    assert desktop._quit_if_ready()
    assert calls == ['open', 'open', 'shutdown']


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows native window lifecycle')
def test_registered_tray_hides_and_reopens_without_exiting():
    from gaociyuan.desktop import Desktop

    calls = []
    desktop = object.__new__(Desktop)
    ticks = iter([False, True])
    desktop.server = SimpleNamespace(shutdown_requested=SimpleNamespace(wait=lambda _: next(ticks)),
                                     request_shutdown=lambda: calls.append('stop'),
                                     drain_work=lambda: calls.append('drain'))
    desktop.instance = SimpleNamespace(read_route=lambda: '')
    desktop.hidden = desktop.ready = desktop.panel_ready = desktop.exiting = False
    desktop.tray = SimpleNamespace(registered=True, start=lambda: calls.append('tray-start'),
                                   stop=lambda: calls.append('tray-stop'))
    desktop.main = SimpleNamespace(hide=lambda: calls.append('hide'), destroy=lambda: calls.append('main-destroy'))
    desktop.panel = SimpleNamespace(destroy=lambda: calls.append('panel-destroy'))
    desktop.open_main = lambda fragment: calls.append(('restore', fragment))
    desktop._close_requested = threading.Event()
    desktop._quit_requested = threading.Event()
    desktop._tray_status = lambda: None

    assert desktop._close_main() is False
    desktop._run()
    assert calls == ['tray-start', 'hide', ('restore', None), 'stop', 'drain', 'tray-stop', 'panel-destroy', 'main-destroy']


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows notification area')
def test_failed_tray_registration_is_retried_after_taskbar_recreation():
    from gaociyuan.desktop import DesktopTray, tray_win32
    from PIL import Image

    metrics, frames, releases = [(16, 16)], [], []

    def create(size, warning):
        frames.append((size, warning))
        return len(frames) * 100

    def release():
        if tray._icon_handle:
            releases.append(tray._icon_handle)
            tray._icon_handle = None

    icons = SimpleNamespace(tray_size=lambda: metrics[-1], create=create, pixels=lambda size: Image.new('RGBA', size))
    tray = DesktopTray(SimpleNamespace(), icons, None)
    tray._visible = True
    tray._release_icon = release
    calls = []
    answers = iter([False, False, True, True, True])

    def message(code, flags, **fields):
        calls.append((code, fields.get('hIcon')))
        return next(answers)

    tray._message = message
    tray._show()
    assert not tray.registered
    metrics.append((24, 24))
    tray._on_taskbarcreated(0, 0)
    assert tray.registered
    tray.update_status(True)
    tray.update_status(True)
    tray._hide()
    assert not tray.registered
    tray._stop_requested.set()
    tray._on_taskbarcreated(0, 0)
    assert not tray.registered
    tray._visible = False
    tray._release_icon()
    assert frames == [((16, 16), False), ((24, 24), False), ((24, 24), True)]
    assert releases == [100, 200, 300]
    assert calls == [
        (tray_win32.NIM_ADD, 100), (tray_win32.NIM_MODIFY, 100), (tray_win32.NIM_ADD, 200),
        (tray_win32.NIM_MODIFY, 300), (tray_win32.NIM_DELETE, None),
    ]


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows native HWND icon messages')
def test_main_icon_uses_both_dpi_sizes_and_retries_a_timed_out_message():
    from gaociyuan.desktop import Desktop, ICON_BIG, ICON_SMALL, WM_SETICON, SMTO_ABORTIFHUNG, SMTO_ERRORONEXIT

    desk = object.__new__(Desktop)
    desk.hidden = False
    desk.main = object()
    desk._main_icon_state = None
    desk._main_icons = {}
    sizes, messages = [], []
    hwnd, dpi, timeout_once = 100, 96, False

    def create(size):
        sizes.append(size)
        return size[0] + 1000

    def send(window, message, icon_type, icon, flags, timeout, result):
        nonlocal timeout_once
        messages.append((window.value, message, icon_type, icon))
        assert timeout == 100 and flags == SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT
        if timeout_once:
            timeout_once = False
            return 0
        return 1

    def size(dpi, *, small):
        edge = (16 if small else 32) * dpi // 96
        return edge, edge

    desk.handle = lambda _: hwnd
    desk._icon_assets = SimpleNamespace(create=create, size=size)
    desk.user32 = SimpleNamespace(GetDpiForWindow=lambda _: dpi, SendMessageTimeoutW=send)
    desk._update_main_icons()
    desk._update_main_icons()
    dpi, timeout_once = 144, True
    desk._update_main_icons()
    assert desk._main_icon_state == (100, 96)
    desk._update_main_icons()
    hwnd = 200
    desk._update_main_icons()
    assert sizes == [(16, 16), (32, 32), (24, 24), (48, 48)]
    assert messages == [
        (100, WM_SETICON, ICON_SMALL, 1016), (100, WM_SETICON, ICON_BIG, 1032),
        (100, WM_SETICON, ICON_SMALL, 1024),
        (100, WM_SETICON, ICON_SMALL, 1024), (100, WM_SETICON, ICON_BIG, 1048),
        (200, WM_SETICON, ICON_SMALL, 1024), (200, WM_SETICON, ICON_BIG, 1048),
    ]


@pytest.mark.skipif(sys.platform != 'win32', reason='Windows native PNG-to-HICON')
def test_native_icon_uses_real_ico_frame_and_warning_preserves_cached_pixels(tmp_path):
    from ctypes import wintypes
    from io import BytesIO
    from PIL import Image
    from gaociyuan.desktop import WindowsIconAssets

    main = Image.new('RGBA', (32, 32), '#ff9032')
    exact = Image.new('RGBA', (24, 24), '#3d805e')
    exact.putpixel((0, 0), (0, 0, 0, 0))
    main.save(tmp_path / 'GaoCiYuan.ico', sizes=[exact.size, main.size], append_images=[exact])
    icons = WindowsIconAssets(ctypes.WinDLL('user32'), tmp_path)
    assert icons.pixels(exact.size).tobytes() == exact.tobytes()
    handle = icons.create(exact.size)
    assert handle
    assert icons.user32.DestroyIcon(handle)

    def create(data, length, is_icon, version, width, height, flags):
        assert is_icon and version == 0x00030000 and (width, height) == exact.size and flags == 0
        with Image.open(BytesIO(ctypes.string_at(data, length))) as preview:
            assert preview.size == exact.size
            assert preview.getpixel((0, 0))[3] == 0
            assert preview.getpixel((width - 4, 4)) != exact.getpixel((width - 4, 4))
        return 123

    dpi = [144]
    taskbar = [456]
    icons.user32 = SimpleNamespace(
        CreateIconFromResourceEx=create, FindWindowW=lambda *_: taskbar[0],
        GetDpiForWindow=lambda _: dpi[0], GetDpiForSystem=lambda: 120,
        GetSystemMetricsForDpi=lambda _, value: int(value) // 6,
    )
    assert icons.tray_size() == exact.size
    assert icons.create(exact.size, warning=True) == 123
    assert icons.pixels(exact.size).tobytes() == exact.tobytes()
    taskbar[0] = None
    assert icons.tray_size() == (20, 20)
    taskbar[0], dpi[0] = 456, 0
    assert icons.tray_size() == (20, 20)
