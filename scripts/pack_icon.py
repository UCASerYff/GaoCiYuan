#!/usr/bin/env python3
"""Package PNG icon representations without modifying the generated artwork."""
import pathlib, struct, sys
root, dest = map(pathlib.Path, sys.argv[1:])
formats = {'icp4':'icon_16x16.png', 'icp5':'icon_32x32.png', 'icp6':'icon_32x32@2x.png', 'ic07':'icon_128x128.png', 'ic08':'icon_256x256.png', 'ic09':'icon_512x512.png', 'ic10':'icon_512x512@2x.png', 'ic11':'icon_16x16@2x.png', 'ic12':'icon_32x32@2x.png', 'ic13':'icon_128x128@2x.png', 'ic14':'icon_256x256@2x.png'}
chunks = []
for tag, file in formats.items():
    data = (root/file).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(tag.encode() + struct.pack('>I',len(data)+8) + data)
body = b''.join(chunks)
dest.write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
