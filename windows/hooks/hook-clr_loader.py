"""Bundle only the AMD64 .NET Framework bootstrap from clr_loader."""

from pathlib import Path

from PyInstaller.utils.hooks import get_package_paths


_, package = get_package_paths('clr_loader')
engine = 'ffi/dlls/amd64'
binaries = [(str(Path(package) / engine / 'ClrLoader.dll'), f'clr_loader/{engine}')]
