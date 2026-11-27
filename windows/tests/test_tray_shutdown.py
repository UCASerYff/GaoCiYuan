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

    tray = object.__new__(DesktopTray)
    tray._running = False
    tray._visible = True
    tray._title = 'GaoCiYuan'
    tray._icon_handle = None
    tray.registered = False
    tray._assert_icon_handle = lambda: None
    calls = []
    answers = iter([False, False, True, True])

    def message(code, flags, **fields):
        calls.append(code)
        return next(answers)

    tray._message = message
    tray._show()
    assert not tray.registered
    tray._on_taskbarcreated(0, 0)
    assert tray.registered
    tray._hide()
    assert not tray.registered
    assert calls == [tray_win32.NIM_ADD, tray_win32.NIM_MODIFY, tray_win32.NIM_ADD, tray_win32.NIM_DELETE]
