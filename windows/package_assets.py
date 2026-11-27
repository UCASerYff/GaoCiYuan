"""Convert the shared brand image and write PE version resources at build time."""

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent / 'src'))

from gaociyuan.version import APP_NAME, MARKETING_VERSION, WINDOWS_BUILD


def main() -> None:
    resources, ico, version_info = map(Path, sys.argv[1:])
    with Image.open(resources / 'GaoCiYuanIcon.png') as source:
        source.convert('RGBA').save(ico, sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
    tuple_version = (*map(int, MARKETING_VERSION.split('.')), int(WINDOWS_BUILD), 0)
    file_version = f'{MARKETING_VERSION}.{WINDOWS_BUILD}.0'
    version_info.write_text(f'''# UTF-8
VSVersionInfo(
  ffi=FixedFileInfo(filevers={tuple_version!r}, prodvers={tuple_version!r}, mask=0x3f,
    flags=0, OS=0x40004, fileType=0x1, subtype=0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('080404b0', [
    StringStruct('CompanyName', 'GaoSeries'),
    StringStruct('FileDescription', {APP_NAME!r}),
    StringStruct('FileVersion', {file_version!r}),
    StringStruct('ProductName', {APP_NAME!r}),
    StringStruct('ProductVersion', {MARKETING_VERSION!r}),
  ])]), VarFileInfo([VarStruct('Translation', [2052, 1200])])]
)
''', encoding='utf-8')


if __name__ == '__main__':
    main()
