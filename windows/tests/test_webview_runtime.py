from __future__ import annotations

import ctypes
import importlib
import os
import sys
import threading
from types import ModuleType, SimpleNamespace

import pytest

from gaociyuan import cli, instance, webview_runtime as runtime
from gaociyuan.errors import AppError


@pytest.mark.parametrize(('version', 'hresult', 'available'), [
    ('140.0.3485.94', 0, True),
    ('0.0.0.0', 0, False),
    ('   ', 0, False),
    ('140.0.3485.94', -2147024894, False),
    (None, 0, False),
])
def test_loader_requires_a_positive_version_and_frees_sdk_result(monkeypatch, tmp_path, version, hresult,
                                                                 available):
    buffer = ctypes.create_unicode_buffer(version) if version is not None else None
    loader_path = tmp_path / runtime.LOADER
    libraries, freed = [], []

    def probe(folder, result):
        assert folder is None
        if buffer is not None:
            ctypes.cast(result, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(buffer)
        return hresult

    def release(result):
        freed.append(result.value)

    def win_dll(name):
        libraries.append(name)
        if name == str(loader_path):
            return SimpleNamespace(GetAvailableCoreWebView2BrowserVersionString=probe)
        assert name == 'ole32'
        return SimpleNamespace(CoTaskMemFree=release)

    monkeypatch.setattr(ctypes, 'WinDLL', win_dll, raising=False)
    if available:
        assert runtime.installed_webview2_version(loader_path) == version
    else:
        with pytest.raises(AppError, match='Evergreen Runtime'):
            runtime.installed_webview2_version(loader_path)
    assert libraries == [str(loader_path), 'ole32']
    assert freed == ([ctypes.addressof(buffer)] if buffer is not None else [])


@pytest.mark.parametrize(('frozen', 'mode'), [
    (False, 'edgechromium'),
    (True, 'edgechromium'),
    (False, 'mshtml'),
    (False, 'try-alternate'),
    (False, 'missing-runtime'),
])
def test_native_requires_exact_x64_loader_and_effective_edge_renderer(monkeypatch, tmp_path, frozen, mode):
    package = tmp_path / 'webview'
    monkeypatch.setattr(sys, 'frozen', frozen, raising=False)
    monkeypatch.setattr(sys, '_MEIPASS', str(tmp_path), raising=False)
    monkeypatch.setattr(runtime, 'find_spec', lambda _: SimpleNamespace(origin=package / '__init__.py'))
    blocked_modules = [f'webview.platforms.{name}' for name in runtime.OTHER_BACKENDS]
    for name in blocked_modules:
        monkeypatch.setitem(sys.modules, name, None)
        del sys.modules[name]

    calls = []

    def probe(loader_path):
        calls.append(loader_path)
        if mode == 'missing-runtime':
            raise AppError(runtime.RUNTIME_ERROR)
        return '140.0.3485.94'

    def initialize(gui):
        calls.append(gui)
        if mode == 'try-alternate':
            importlib.import_module('webview.platforms.mshtml')
        return SimpleNamespace(renderer=mode)

    guilib = ModuleType('webview.guilib')
    guilib.initialize = initialize
    monkeypatch.setitem(sys.modules, 'webview.guilib', guilib)
    monkeypatch.setattr(runtime, 'installed_webview2_version', probe)

    if mode == 'edgechromium':
        runtime.require_webview2()
    else:
        with pytest.raises(AppError, match='Evergreen Runtime'):
            runtime.require_webview2()
    assert calls == [package / runtime.LOADER] + ([] if mode == 'missing-runtime' else ['edgechromium'])
    assert all((name in sys.modules) == (mode != 'missing-runtime') for name in blocked_modules)


def test_missing_sdk_dependency_has_a_distinct_error(monkeypatch, tmp_path):
    def missing_dll(_):
        raise OSError('sensitive path')

    monkeypatch.setattr(ctypes, 'WinDLL', missing_dll, raising=False)
    with pytest.raises(AppError) as error:
        runtime.installed_webview2_version(tmp_path / runtime.LOADER)
    assert error.value.message == runtime.DEPENDENCY_ERROR


@pytest.mark.skipif(os.name != 'nt', reason='Windows desktop entry point')
def test_desktop_aborts_before_loading_data_or_opening_browser_if_runtime_is_unavailable(monkeypatch, tmp_path):
    events = []

    def fail_probe():
        raise AppError(runtime.RUNTIME_ERROR)

    def unexpected(*args, **kwargs):
        pytest.fail('Desktop runtime failure must stop before store or serve.')

    monkeypatch.setattr(instance, 'Instance', lambda _: SimpleNamespace(primary=True, close=lambda: events.append('close')))
    monkeypatch.setattr(runtime, 'require_webview2', fail_probe)
    monkeypatch.setattr(runtime, 'startup_error', events.append)
    monkeypatch.setattr(cli, 'open_credential_store', unexpected)
    monkeypatch.setattr(cli, 'TokenStore', unexpected)
    monkeypatch.setattr(cli, 'serve', unexpected)

    assert cli.main(['--data-dir', str(tmp_path)]) == 2
    assert events == [runtime.RUNTIME_ERROR, 'close']


@pytest.mark.parametrize(('args', 'console', 'opens_browser'), [
    (['--serve'], False, True),
    (['--serve', '--no-browser'], True, False),
    (['--no-browser'], False, False),
])
def test_explicit_browser_and_headless_entry_points_bypass_edge_probe(monkeypatch, tmp_path, args, console, opens_browser):
    stopped = threading.Event()
    stopped.set()
    calls = []

    def unexpected():
        pytest.fail('The browser and headless modes must run without WebView2.')

    def serve(store, **options):
        calls.append(options['open_browser'])
        return SimpleNamespace(shutdown_requested=stopped, request_shutdown=stopped.set, shutdown=lambda: None,
                               server_close=lambda: None, drain_work=lambda: None)

    monkeypatch.setattr(runtime, 'require_webview2', unexpected)
    monkeypatch.setattr(cli, 'serve', serve)

    assert cli.main(['--data-dir', str(tmp_path), '--no-refresh', *args], console=console) == 0
    assert calls == [opens_browser]
