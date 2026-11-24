#!/usr/bin/env python3
"""Generate the opaque 1024px AzaharFE icon without external dependencies."""
from pathlib import Path
import math
import struct
import zlib

SIZE = 1024
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

def rounded(x, y, cx, cy, w, h, r):
    dx = abs(x-cx) - (w/2-r)
    dy = abs(y-cy) - (h/2-r)
    d = math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - r
    return max(0.0, min(1.0, 0.5-d))

def circle(x, y, cx, cy, r):
    return max(0.0, min(1.0, r+0.5-math.hypot(x-cx,y-cy)))

def blend(c, target, a):
    return tuple(round(v+(t-v)*a) for v,t in zip(c,target))

rows = bytearray()
for y in range(SIZE):
    rows.append(0)
    for x in range(SIZE):
        glow = max(0.0, 1.0-math.hypot(x-400,y-260)/850)
        c = (int(9+20*glow), int(18+45*glow), int(40+75*glow))
        # Original two-screen handheld emblem; no third-party artwork.
        if 150 < x < 875 and 170 < y < 875:
            c = blend(c,(4,10,26),rounded(x,y,512,520,680,670,106)*0.65)
            c = blend(c,(76,177,247),rounded(x,y,512,500,658,640,91))
            c = blend(c,(21,43,76),rounded(x,y,512,500,638,620,83))
            c = blend(c,(110,203,255),rounded(x,y,512,345,510,254,41))
            c = blend(c,(10,27,52),rounded(x,y,512,345,484,228,30))
            c = blend(c,(28,85,139),rounded(x,y,512,345,448,192,23))
            # Diagonal abstract screen gleam.
            if 304 < x < 720 and 260 < y < 430:
                gleam = max(0.0, 1.0-abs((x-512)+(y-345)*1.7)/100)
                c = blend(c,(62,133,190),gleam*0.6)
            c = blend(c,(110,203,255),rounded(x,y,512,621,300,214,33))
            c = blend(c,(10,27,52),rounded(x,y,512,621,276,190,23))
            c = blend(c,(32,107,165),rounded(x,y,512,621,248,162,18))
            c = blend(c,(160,211,251),rounded(x,y,276,621,112,34,10))
            c = blend(c,(160,211,251),rounded(x,y,276,621,34,112,10))
            for cx,cy in [(748,574),(793,621),(748,668),(703,621)]:
                c = blend(c,(255,207,105),circle(x,y,cx,cy,18))
            c = blend(c,(255,207,105),rounded(x,y,512,756,100,12,6))
        rows.extend(c)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", SIZE,SIZE,8,2,0,0,0))
png += chunk(b"IDAT", zlib.compress(bytes(rows),9)) + chunk(b"IEND",b"")
path = Path(__file__).resolve().parents[1] / "AzaharIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
path.parent.mkdir(parents=True,exist_ok=True)
path.write_bytes(png)
print(f"Created {path} ({len(png)} bytes)")
