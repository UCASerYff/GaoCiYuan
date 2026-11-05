#!/usr/bin/env python3
"""Verify the copied native Claude flower with Python's standard library only.

No UI, app process, renderer, network or image-generation tool is started.
"""

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path


EXPECTED_SHA256 = "2f49a540e997e57ef3ceebc55bc325b2f62651b2dcc48d3753ef31fb0602e2a4"


def rgba_pixels(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "Native resource is not PNG"
    offset, compressed, header = 8, bytearray(), None
    while offset < len(data):
        count = struct.unpack_from(">I", data, offset)[0]
        name = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + count]
        crc = struct.unpack_from(">I", data, offset + 8 + count)[0]
        assert zlib.crc32(name + body) & 0xFFFFFFFF == crc, "PNG chunk checksum failed"
        if name == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif name == b"IDAT":
            compressed.extend(body)
        offset += count + 12
    assert header == (72, 72, 8, 6, 0, 0, 0), "Native flower must stay 72x72 RGBA"
    width, height = header[:2]
    raw, stride = zlib.decompress(compressed), width * 4
    assert len(raw) == height * (stride + 1), "Native PNG scanlines are incomplete"
    previous, pixels = bytearray(stride), []
    for y in range(height):
        begin = y * (stride + 1)
        kind, row = raw[begin], bytearray(raw[begin + 1:begin + 1 + stride])
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            above, corner = previous[x], previous[x - 4] if x >= 4 else 0
            if kind == 0:
                predictor = 0
            elif kind == 1:
                predictor = left
            elif kind == 2:
                predictor = above
            elif kind == 3:
                predictor = (left + above) // 2
            elif kind == 4:
                p = left + above - corner
                distances = (abs(p - left), abs(p - above), abs(p - corner))
                predictor = (left, above, corner)[distances.index(min(distances))]
            else:
                raise AssertionError("Unsupported PNG filter")
            row[x] = (row[x] + predictor) & 0xFF
        pixels.extend(tuple(row[x:x + 4]) for x in range(0, stride, 4))
        previous = row
    return pixels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("project_root", type=Path)
    parser.add_argument("--native-resource", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    resource = args.project_root / "Resources/PanelIcons/claude-native-white-flower.png"
    provenance = json.loads((resource.parent / "claude-native-white-flower-source.json").read_text())
    data = resource.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == EXPECTED_SHA256 == provenance["sha256"], "Native flower pixels changed"
    assert len(data) == provenance["bytes"] == 4004, "Native resource size changed"
    assert provenance["source_bundle_id"] == "com.anthropic.claudefordesktop"
    pixels = rgba_pixels(data)
    transparent = sum(alpha == 0 for _, _, _, alpha in pixels)
    white = sum(min(red, green, blue) >= 240 and alpha >= 192 for red, green, blue, alpha in pixels)
    assert transparent > 1000 and white > 300, "Resource is not the native transparent white flower"
    same_source = None
    if args.native_resource is not None:
        same_source = args.native_resource.read_bytes() == data
        assert same_source, "Copied flower differs from the authorized native Claude resource"
    result = {
        "passed": True,
        "resource": "Resources/PanelIcons/claude-native-white-flower.png",
        "source_bundle_id": provenance["source_bundle_id"],
        "source_version": provenance["source_version"],
        "sha256": digest,
        "bytes": len(data),
        "dimensions": [72, 72],
        "fully_transparent_pixels": transparent,
        "near_white_visible_pixels": white,
        "native_resource_bytes_equal": same_source,
        "validation": "PNG CRC/decoding, original source SHA/bytes, white petals and transparency",
        "gui_or_app_launched": False,
        "smoke_test_run": False,
    }
    if args.receipt is not None:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
