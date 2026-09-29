#!/usr/bin/env python3
"""xwd → png(本机无 PIL/convert)。用法: xwd2png.py in.xwd out.png [缩放倍数分母,默认2]"""
import sys, struct, zlib
b = open(sys.argv[1], 'rb').read()
h = struct.unpack('>25I', b[:100]); hs, w, H, bpp, bpl, nc = h[0], h[4], h[5], h[11], h[12], h[19]
d = b[hs + nc * 12:]; st = bpp // 8; k = int(sys.argv[3]) if len(sys.argv) > 3 else 2
W2, H2 = w // k, H // k
raw = bytearray()
for y in range(H2):
    raw.append(0); row = y * k * bpl
    for x in range(W2):
        p = row + x * k * st; raw += bytes((d[p+2], d[p+1], d[p]))
def chunk(t, c): return struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W2, H2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png); print(f"{sys.argv[2]} {W2}x{H2}")
