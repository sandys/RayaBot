#!/usr/bin/env python3
"""Report the true colours inside PNG files embedded in a xiaozhi assets image (or any file).

Usage:
    png_probe.py <file> [--name neutral.png] [--all]

Why
    Screenshots decoded from the device are rendered by LVGL and pass through a JPEG encoder.
    To tell "the artwork really is this colour" apart from "a colour channel got swapped on the
    way", read the source pixels straight out of the PNG data that was flashed.

How
    Finds every embedded PNG (by signature), decodes it with the standard library only
    (zlib + the five PNG scanline filters; 8-bit RGB / RGBA / grey / palette, non-interlaced),
    and prints size, colour type and the colours at a few points plus the most common opaque
    colours. With xiaozhi assets the PNG order follows index.json; --name picks one by the
    file name recorded in the assets table when it can be found next to the data.
"""
import argparse
import collections
import struct
import sys
import zlib

SIG = b"\x89PNG\r\n\x1a\n"


def find_pngs(data):
    out, i = [], 0
    while True:
        i = data.find(SIG, i)
        if i < 0:
            return out
        j, end = i + 8, None
        while j + 8 <= len(data):
            (length,) = struct.unpack(">I", data[j:j + 4])
            ctype = data[j + 4:j + 8]
            j += 12 + length
            if ctype == b"IEND":
                end = j
                break
        if end:
            out.append((i, data[i:end]))
        i += 8


def decode(png):
    pos, idat, plte, trns = 8, b"", None, None
    w = h = depth = ctype = interlace = None
    while pos < len(png):
        (length,) = struct.unpack(">I", png[pos:pos + 4])
        t = png[pos + 4:pos + 8]
        body = png[pos + 8:pos + 8 + length]
        pos += 12 + length
        if t == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif t == b"PLTE":
            plte = [tuple(body[k:k + 3]) for k in range(0, len(body), 3)]
        elif t == b"tRNS":
            trns = body
        elif t == b"IDAT":
            idat += body
        elif t == b"IEND":
            break
    if depth != 8 or interlace:
        raise ValueError(f"unsupported: bit depth {depth}, interlace {interlace}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    stride = w * channels
    raw = zlib.decompress(idat)
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line))
        prev = line

    def px(x, y):
        r = rows[y]
        if ctype == 6:
            return tuple(r[4 * x:4 * x + 4])
        if ctype == 2:
            return tuple(r[3 * x:3 * x + 3]) + (255,)
        if ctype == 0:
            return (r[x],) * 3 + (255,)
        if ctype == 4:
            return (r[2 * x],) * 3 + (r[2 * x + 1],)
        idx = r[x]
        alpha = trns[idx] if trns and idx < len(trns) else 255
        return tuple(plte[idx]) + (alpha,)

    return w, h, ctype, px


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file")
    ap.add_argument("--all", action="store_true", help="probe every PNG, not just the first three")
    args = ap.parse_args()
    data = open(args.file, "rb").read()
    pngs = find_pngs(data)
    print(f"{len(pngs)} PNG(s) in {args.file}")
    for n, (off, png) in enumerate(pngs if args.all else pngs[:3]):
        w, h, ctype, px = decode(png)
        hist = collections.Counter()
        for y in range(h):
            for x in range(w):
                r, g, b, a = px(x, y)
                if a > 200:
                    hist[(r >> 4 << 4, g >> 4 << 4, b >> 4 << 4)] += 1
        cx, cy = w // 2, h // 2
        print(f"#{n} at 0x{off:x}: {w}x{h} colour type {ctype}")
        for label, (x, y) in (("centre", (cx, cy)), ("left cheek", (w // 5, cy)), ("upper", (cx, h // 5))):
            r, g, b, a = px(x, y)
            print(f"    {label:10s} ({x:2d},{y:2d}) = R{r:3d} G{g:3d} B{b:3d} A{a:3d}  #{r:02x}{g:02x}{b:02x}")
        top = ", ".join(f"#{r:02x}{g:02x}{b:02x}x{c}" for (r, g, b), c in hist.most_common(4))
        print(f"    most common opaque colours (4-bit buckets): {top}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
