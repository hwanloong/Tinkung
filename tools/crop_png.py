"""裁一段 PNG 出来看细节（喂给 read_image）。

## 为什么需要

"颜色对不对"这种事只能看，不能靠断言。整屏截图里输入框那行只有几十像素高，
缩略之后根本分辨不出引用段有没有染色。裁出来一块，一眼就能判断。

用法：
    python tools/crop_png.py <源> <输出> <x0> <y0> <x1> <y1>
"""

from __future__ import annotations

import pathlib
import struct
import sys
import zlib


def read_png(path: str):
    data = pathlib.Path(path).read_bytes()
    pos = 8
    idat = bytearray()
    w = h = 0
    ch = 4
    while pos < len(data):
        ln = struct.unpack(">I", data[pos : pos + 4])[0]
        typ = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + ln]
        if typ == b"IHDR":
            w, h, _bd, ct = struct.unpack(">IIBB", body[:10])
            ch = 3 if ct == 2 else 4
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + ln

    raw = zlib.decompress(bytes(idat))
    stride = w * ch
    out = []
    prev = bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i : i + stride])
        i += stride
        if f == 1:
            for x in range(ch, stride):
                line[x] = (line[x] + line[x - ch]) & 0xFF
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif f == 3:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif f == 4:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0
                c = prev[x - ch] if x >= ch else 0
                b = prev[x]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
        out.append(bytes(line))
        prev = line
    return w, h, ch, out


def write_png(path: str, w: int, h: int, rows: list[bytes]) -> None:
    raw = bytearray()
    for r in rows:
        raw.append(0)
        raw += r

    def chunk(t: bytes, d: bytes) -> bytes:
        return (
            struct.pack(">I", len(d))
            + t
            + d
            + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    pathlib.Path(path).write_bytes(png)


def main() -> int:
    if len(sys.argv) != 7:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    x0, y0, x1, y1 = (int(v) for v in sys.argv[3:7])
    w, h, ch, rows = read_png(src)
    x1 = min(x1, w)
    y1 = min(y1, h)
    crop: list[bytes] = []
    for y in range(y0, y1):
        line = bytearray()
        for x in range(x0, x1):
            o = x * ch
            line += rows[y][o : o + 3]
        crop.append(bytes(line))
    write_png(dst, x1 - x0, y1 - y0, crop)
    print(f"{dst}  {x1 - x0}x{y1 - y0}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
