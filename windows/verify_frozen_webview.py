"""Validate the actual onedir payload without launching either executable."""

import sys
from pathlib import Path

from PyInstaller.archive.readers import CArchiveReader


EDGE_MODULE = 'webview.platforms.edgechromium'
BACKENDS = {EDGE_MODULE, 'webview.platforms.winforms'}
EDGE_LOADER = 'webview/lib/runtimes/win-x64/native/WebView2Loader.dll'
EDGE_FILES = {EDGE_LOADER, 'webview/lib/Microsoft.Web.WebView2.Core.dll',
              'webview/lib/Microsoft.Web.WebView2.WinForms.dll'}
CLR_LOADER = 'clr_loader/ffi/dlls/amd64/ClrLoader.dll'


def verify(executable: Path) -> None:
    archive = CArchiveReader(str(executable))
    pyz = next(name for name, entry in archive.toc.items() if entry[-1] == 'z')
    code_archive = archive.open_embedded_archive(pyz)
    backends = {name for name in code_archive.toc if name.startswith('webview.platforms.')}
    if backends != BACKENDS:
        raise ValueError(f'{executable.name} has incorrect WebView modules: {sorted(backends)}')
    if 'win-x64' not in code_archive.extract(EDGE_MODULE).co_consts:
        raise ValueError(f'{executable.name} lacks the staged x64 Edge loader lookup.')

    data = executable.parent / '_internal'
    if any((data / 'webview/platforms').rglob('*.py')):
        raise ValueError(f'{executable.name} has loose WebView platform source files.')
    lib_files = {path.relative_to(data).as_posix() for path in (data / 'webview/lib').rglob('*') if path.is_file()}
    if lib_files != EDGE_FILES:
        raise ValueError(f'{executable.name} has incorrect WebView library files: {sorted(lib_files)}')
    for name, expected in (('WebView2Loader.dll', EDGE_LOADER), ('ClrLoader.dll', CLR_LOADER)):
        loaders = {path.relative_to(data).as_posix() for path in data.rglob(name)}
        if loaders != {expected}:
            raise ValueError(f'{executable.name} has incorrect {name} files: {sorted(loaders)}')
    print(f'{executable.name}: x64 Edge WebView2 and x64 .NET bootstrap verified.')


if __name__ == '__main__':
    for argument in sys.argv[1:]:
        verify(Path(argument))
