"""Convert the shared brand image and write PE version resources at build time."""

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent / 'src'))

from gaociyuan.version import APP_NAME, MARKETING_VERSION, WINDOWS_BUILD


ICON_SIZES = (16, 20, 24, 28, 30, 32, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256)
CORNER_RADIUS_RATIO = 0.20


def write_icon(source: Path, target: Path) -> None:
    with Image.open(source) as png:
        master = png.convert('RGBA')
    width, height = master.size
    if width != height or width < ICON_SIZES[-1]:
        raise ValueError('The Windows icon source must be square and at least 256 pixels wide.')

    mask = Image.new('L', master.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), round(width * CORNER_RADIUS_RATIO), fill=255)
    master.putalpha(ImageChops.multiply(master.getchannel('A'), mask))

    # Match native shell/tray sizes at 100%, 125%, 150%, 175%, and 200% without rescaling a smaller frame.
    sizes = [(edge, edge) for edge in ICON_SIZES]
    premultiplied = master.convert('RGBa')
    frames = [premultiplied.resize(size, Image.Resampling.LANCZOS).convert('RGBA') for size in sizes]
    frames[-1].save(target, sizes=sizes, append_images=frames[:-1])


def main() -> None:
    resources, ico, version_info = map(Path, sys.argv[1:])
    write_icon(resources / 'GaoCiYuanIcon.png', ico)
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
