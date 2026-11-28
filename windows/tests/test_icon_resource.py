from __future__ import annotations

import ctypes
import io
import struct
import subprocess
import sys
from ctypes import wintypes
from pathlib import Path

import pytest
from PIL import Image


SCALES = (100, 125, 150, 175, 200)
SIZES = sorted({size * scale // 100 for size in (16, 24, 32, 48) for scale in SCALES} | {128, 256})


@pytest.fixture(scope='module')
def ico(tmp_path_factory):
    windows = Path(__file__).resolve().parents[1]
    scratch = tmp_path_factory.mktemp('windows-icon')
    packed = scratch / 'GaoCiYuan.ico'
    subprocess.run([sys.executable, str(windows / 'package_assets.py'), str(windows.parent / 'Resources'),
                    str(packed), str(scratch / 'version.info')], check=True)
    return packed


def test_ico_contains_exact_antialiased_frames(ico):
    data = ico.read_bytes()
    assert struct.unpack_from('<HHH', data) == (0, 1, len(SIZES))
    offset = 6 + 16 * len(SIZES)
    for index, size in enumerate(SIZES):
        width, height, palette, reserved, _, bits, length, frame_offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * index)
        assert (width or 256, height or 256, palette, reserved, bits) == (size, size, 0, 0, 32)
        assert frame_offset == offset
        offset += length
        assert offset <= len(data)
        with Image.open(io.BytesIO(data[frame_offset:offset])) as frame:
            assert frame.format == 'PNG' and frame.mode == 'RGBA' and frame.size == (size, size)
            alpha = frame.getchannel('A')
            assert all(alpha.getpixel(point) <= 16 for point in ((0, 0), (0, size - 1), (size - 1, 0), (size - 1, size - 1)))
            assert alpha.getpixel((size // 2, 0)) == 255
            assert any(alpha.histogram()[1:255])
            center = frame.crop((size // 4, size // 5, size - size // 4, size - size // 5)).convert('L')
            dark, light = center.getextrema()
            assert dark <= 12 and light >= 175
    assert offset == len(data)


@pytest.mark.skipif(sys.platform != 'win32', reason='Win32 icon resource decoder')
def test_windows_loads_every_packed_size(ico):
    class IconInfo(ctypes.Structure):
        _fields_ = [('fIcon', wintypes.BOOL), ('xHotspot', wintypes.DWORD), ('yHotspot', wintypes.DWORD),
                    ('hbmMask', wintypes.HBITMAP), ('hbmColor', wintypes.HBITMAP)]

    class Bitmap(ctypes.Structure):
        _fields_ = [('bmType', wintypes.LONG), ('bmWidth', wintypes.LONG), ('bmHeight', wintypes.LONG),
                    ('bmWidthBytes', wintypes.LONG), ('bmPlanes', wintypes.WORD), ('bmBitsPixel', wintypes.WORD),
                    ('bmBits', ctypes.c_void_p)]

    user32 = ctypes.WinDLL('user32', use_last_error=True)
    gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)
    user32.LoadImageW.argtypes = (wintypes.HINSTANCE, wintypes.LPCWSTR, wintypes.UINT, ctypes.c_int, ctypes.c_int, wintypes.UINT)
    user32.LoadImageW.restype = wintypes.HANDLE
    user32.GetIconInfo.argtypes = (wintypes.HICON, ctypes.POINTER(IconInfo))
    user32.DestroyIcon.argtypes = (wintypes.HICON,)
    user32.GetSystemMetricsForDpi.argtypes = (ctypes.c_int, wintypes.UINT)
    user32.GetSystemMetricsForDpi.restype = ctypes.c_int
    gdi32.GetObjectW.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p)
    gdi32.DeleteObject.argtypes = (wintypes.HANDLE,)
    image_icon, load_from_file = 1, 0x10

    for scale in SCALES:
        dpi = 96 * scale // 100
        for width, height in ((49, 50), (11, 12)):  # SM_CX/CYSMICON and SM_CX/CYICON
            metrics = [user32.GetSystemMetricsForDpi(index, dpi) for index in (width, height)]
            assert all(metric in SIZES for metric in metrics), (dpi, metrics)

    for size in SIZES:
        icon = user32.LoadImageW(None, str(ico), image_icon, size, size, load_from_file)
        assert icon, f'LoadImageW failed for {size}px ({ctypes.get_last_error()})'
        info = IconInfo()
        try:
            assert user32.GetIconInfo(icon, ctypes.byref(info))
            bitmap = Bitmap()
            assert gdi32.GetObjectW(info.hbmColor, ctypes.sizeof(bitmap), ctypes.byref(bitmap)) == ctypes.sizeof(bitmap)
            assert (bitmap.bmWidth, bitmap.bmHeight, bitmap.bmBitsPixel) == (size, size, 32)
        finally:
            if info.hbmMask:
                gdi32.DeleteObject(info.hbmMask)
            if info.hbmColor:
                gdi32.DeleteObject(info.hbmColor)
            user32.DestroyIcon(icon)
