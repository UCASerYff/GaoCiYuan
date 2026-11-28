from types import SimpleNamespace

import pytest

import stage_webview


def test_staged_backend_resolves_only_the_existing_x64_runtime(tmp_path):
    expected_directory = tmp_path / 'win-x64'
    expected_directory.mkdir()
    environment = {'Path': 'existing'}

    def runtime(name):
        selected = tmp_path / name
        assert selected.is_dir()
        return str(selected)

    patched = stage_webview.x64_backend(stage_webview.MULTI_ARCH_LOOKUP)
    exec(patched, {'os': SimpleNamespace(environ=environment), 'interop_dll_path': runtime})
    assert environment['Path'] == 'existing;' + str(expected_directory)


@pytest.mark.parametrize('source', ['', stage_webview.MULTI_ARCH_LOOKUP * 2])
def test_stage_rejects_unrecognized_upstream_code(source):
    with pytest.raises(ValueError, match='Recheck the pinned pywebview'):
        stage_webview.x64_backend(source)


def test_stage_preserves_the_installed_dependency(monkeypatch, tmp_path):
    upstream = tmp_path / 'installed' / 'webview'
    backend = upstream / 'platforms' / 'edgechromium.py'
    backend.parent.mkdir(parents=True)
    backend.write_text(stage_webview.MULTI_ARCH_LOOKUP, encoding='utf-8')
    package = upstream / '__init__.py'
    package.touch()
    for arch in ('win-x64', 'win-x86', 'win-arm64'):
        loader = upstream / 'lib' / 'runtimes' / arch / 'native' / 'WebView2Loader.dll'
        loader.parent.mkdir(parents=True)
        loader.write_bytes(arch.encode('ascii'))
    monkeypatch.setattr(stage_webview, 'find_spec', lambda _: SimpleNamespace(origin=package))
    monkeypatch.setattr(stage_webview, 'version', lambda _: '6.1')
    out = tmp_path / 'stage'

    stage_webview.stage(out)

    assert backend.read_text(encoding='utf-8') == stage_webview.MULTI_ARCH_LOOKUP
    assert (out / 'webview/platforms/edgechromium.py').read_text(encoding='utf-8') == stage_webview.X64_LOOKUP
    assert [path.read_bytes() for path in out.rglob('WebView2Loader.dll')] == [b'win-x64']
