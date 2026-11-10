#!/usr/bin/env python3
"""Pull XZSHOT screenshots out of a serial capture and write them as image files.

Usage:
    extract_screenshots.py <capture.log> --out-dir <dir> [--prefix NAME]

The dev firmware (patches/…xz-dev…, Kconfig XZ_DEV_SERIAL_SCREENSHOT) prints the active
LVGL screen on the console like this, mixed in with ordinary log lines:

    XZSHOT BEGIN id=1 fmt=jpeg w=240 h=240 bytes=5321 uptime_ms=6012 state=3
    XZSHOT D 1 0 /9j/4AAQSkZJRgABAQ...          (base64, 96 chars per line)
    XZSHOT D 1 1 ...
    XZSHOT END id=1 crc32=1a2b3c4d lines=74

Every data line carries the shot id and a sequence number, so lines from other tasks
that land in between are simply ignored, and a missing line is detected.

For each complete shot this checks: all sequence numbers present, decoded length equals
"bytes", CRC-32 equals "crc32" (zlib polynomial, same as esp_rom_crc32_le(0, …)).
A shot that fails any check is reported and NOT written.

fmt=jpeg   is written as-is (.jpg).
fmt=rgb565 (raw little-endian RGB565, w*h*2 bytes) is converted to a lossless .png.

Prints one line per shot and exits 0 if at least one valid shot was written, 1 otherwise.
Standard library only.
"""
import argparse
import base64
import os
import re
import struct
import sys
import zlib

BEGIN = re.compile(r"XZSHOT BEGIN id=(\d+) fmt=(\w+) w=(\d+) h=(\d+) bytes=(\d+)(.*)")
DATA = re.compile(r"XZSHOT D (\d+) (\d+) ([A-Za-z0-9+/=]+)")
END = re.compile(r"XZSHOT END id=(\d+) crc32=([0-9a-fA-F]{8}) lines=(\d+)")
FAIL = re.compile(r"XZSHOT FAIL(.*)")


def rgb565_to_png(raw: bytes, w: int, h: int) -> bytes:
    """Minimal PNG encoder (8-bit RGB, no filtering)."""
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            (v,) = struct.unpack_from("<H", raw, 2 * (y * w + x))
            r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
            rows += bytes(((r * 255 + 15) // 31, (g * 255 + 31) // 63, (b * 255 + 15) // 31))

    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def self_test() -> int:
    """Build a synthetic capture (one good rgb565 shot with log noise in between, one shot
    with a dropped line, one with a wrong CRC) and check the extractor's verdicts."""
    import subprocess
    import tempfile

    w = h = 240
    raw = bytearray()
    for y in range(h):
        for x in range(w):
            # red ramp left->right, green ramp top->bottom, blue disc in the middle
            r, g = x * 31 // (w - 1), y * 63 // (h - 1)
            b = 31 if (x - 120) ** 2 + (y - 120) ** 2 < 40 ** 2 else 0
            raw += struct.pack("<H", (r << 11) | (g << 5) | b)
    raw = bytes(raw)
    b64 = base64.b64encode(raw).decode()
    lines = [b64[i:i + 96] for i in range(0, len(b64), 96)]

    def block(sid, crc, drop=None):
        out = [f"XZSHOT BEGIN id={sid} fmt=rgb565 w={w} h={h} bytes={len(raw)} uptime_ms=6000 state=3"]
        for i, ln in enumerate(lines):
            if i == drop:
                continue
            out.append(f"XZSHOT D {sid} {i} {ln}")
            if i % 50 == 7:
                out.append("I (6123) SystemInfo: free sram: 149531 minimal sram: 147475")
        out.append(f"XZSHOT END id={sid} crc32={crc:08x} lines={len(lines)}")
        return out

    good = zlib.crc32(raw) & 0xFFFFFFFF
    text = "\n".join(["ESP-ROM:esp32s3-20210327"] + block(1, good) + block(2, good, drop=5) + block(3, good ^ 1)) + "\n"
    with tempfile.TemporaryDirectory() as d:
        cap = os.path.join(d, "cap.log")
        open(cap, "w").write(text)
        res = subprocess.run([sys.executable, os.path.abspath(__file__), cap, "--out-dir", d, "--prefix", "t"],
                             capture_output=True, text=True)
        out = res.stdout
        png = os.path.join(d, "t-01.png")
        checks = {
            "good shot accepted": "OK id=1" in out and os.path.isfile(png),
            "png has a valid signature": os.path.isfile(png) and open(png, "rb").read(8) == b"\x89PNG\r\n\x1a\n",
            "dropped line detected": "BAD id=2" in out and "missing" in out,
            "wrong crc detected": "BAD id=3" in out and "crc32" in out,
            "bad shots not written": not os.path.exists(os.path.join(d, "t-02.png")) and not os.path.exists(os.path.join(d, "t-03.png")),
            "exit code 0 when one shot is valid": res.returncode == 0,
        }
        keep = os.environ.get("XZ_SELFTEST_KEEP")
        if keep and os.path.isfile(png):
            import shutil
            shutil.copy(png, keep)
    ok = True
    for name, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    if not ok:
        print("--- extractor output ---\n" + out)
    print("self-test " + ("passed" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("capture")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--prefix", default="shot")
    args = ap.parse_args()

    shots = {}   # id -> dict
    order = []
    failures = 0
    with open(args.capture, "r", errors="replace") as f:
        for line in f:
            m = BEGIN.search(line)
            if m:
                sid = int(m.group(1))
                shots[sid] = dict(fmt=m.group(2), w=int(m.group(3)), h=int(m.group(4)),
                                  nbytes=int(m.group(5)), extra=m.group(6).strip(), chunks={}, end=None)
                if sid not in order:
                    order.append(sid)
                continue
            m = DATA.search(line)
            if m and int(m.group(1)) in shots:
                shots[int(m.group(1))]["chunks"][int(m.group(2))] = m.group(3)
                continue
            m = END.search(line)
            if m and int(m.group(1)) in shots:
                shots[int(m.group(1))]["end"] = (int(m.group(2), 16), int(m.group(3)))
                continue
            m = FAIL.search(line)
            if m:
                failures += 1
                print(f"DEVICE-FAIL {m.group(1).strip()}")

    os.makedirs(args.out_dir, exist_ok=True)
    written = 0
    for sid in order:
        s = shots[sid]
        tag = f"id={sid} {s['w']}x{s['h']} {s['fmt']} {s['extra']}"
        if s["end"] is None:
            print(f"INCOMPLETE {tag}: no END marker ({len(s['chunks'])} data lines seen)")
            continue
        crc, nlines = s["end"]
        missing = [i for i in range(nlines) if i not in s["chunks"]]
        if missing:
            print(f"BAD {tag}: {len(missing)} of {nlines} data lines missing (first {missing[0]})")
            continue
        try:
            data = base64.b64decode("".join(s["chunks"][i] for i in range(nlines)), validate=True)
        except Exception as e:  # noqa: BLE001
            print(f"BAD {tag}: base64 error {e}")
            continue
        if len(data) != s["nbytes"]:
            print(f"BAD {tag}: decoded {len(data)} bytes, device said {s['nbytes']}")
            continue
        if zlib.crc32(data) & 0xFFFFFFFF != crc:
            print(f"BAD {tag}: crc32 {zlib.crc32(data) & 0xFFFFFFFF:08x} != device {crc:08x}")
            continue
        if s["fmt"] == "jpeg":
            path = os.path.join(args.out_dir, f"{args.prefix}-{sid:02d}.jpg")
            out = data
        elif s["fmt"] == "rgb565":
            if len(data) != s["w"] * s["h"] * 2:
                print(f"BAD {tag}: rgb565 length {len(data)} != w*h*2")
                continue
            path = os.path.join(args.out_dir, f"{args.prefix}-{sid:02d}.png")
            out = rgb565_to_png(data, s["w"], s["h"])
        else:
            print(f"BAD {tag}: unknown format")
            continue
        with open(path, "wb") as o:
            o.write(out)
        written += 1
        print(f"OK {tag} bytes={len(data)} crc=ok -> {path}")

    if not order:
        print("no XZSHOT blocks found in the capture")
    return 0 if written else 1


if __name__ == "__main__":
    sys.exit(main())
