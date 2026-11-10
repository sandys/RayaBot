#!/usr/bin/env python3
"""crosscheck_idf.py — host half of scripts/33-crosscheck-idf-tools.sh.

    python3 -I -B crosscheck_idf.py prepare IMAGE.bin WORKDIR --container-dir DIR [--nvs]
    python3 -I -B crosscheck_idf.py compare IMAGE.bin WORKDIR [--nvs]

Purpose: show that our own parsers (espflash.py) read a flash image the same way
Espressif's tools do. `prepare` cuts the image into the pieces those tools accept and
writes WORKDIR/jobs.txt; scripts/container/flash-crosscheck.sh then runs the tools inside
the ESP-IDF container; `compare` reads their outputs and prints, fact by fact, MATCH or
MISMATCH against what espflash.py says about the same bytes.

What is compared
  partition table   gen_esp32part.py (binary -> CSV; it also verifies the MD5)
                    vs every entry's name/type/subtype/offset/size/flags
  bootloader, apps  esptool image-info: entry point, flash mode/freq/size, chip id, every
                    segment (length, load address, file offset), checksum, appended SHA-256,
                    app / bootloader descriptor fields.  The tool gets the whole region (not
                    cut where *we* think the image ends), so the end of the image is found
                    independently.
  NVS, synthetic    two NVS images built from a CSV by Espressif's nvs_partition_gen (format
                    v2 with a multi-page blob, and legacy v1); espflash.py must decode exactly
                    the values of the CSV, and nvs_tool.py must agree with it entry by entry
  NVS, real (--nvs) nvs_tool.py on the image's own NVS partition(s) vs espflash.py: same
                    keys, types and values. VALUES ARE NEVER PRINTED - only key names and
                    MATCH/MISMATCH, with lengths on a mismatch.

Exit status of compare: 0 = everything matches, 4 = at least one mismatch or a tool failed.
"""

import argparse
import base64
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import espflash as E  # noqa: E402

# ----------------------------------------------------------------------------- synthetic NVS

BIG_BLOB = bytes((i * 7) & 0xFF for i in range(5000))        # > 1 page: forces chunking in v2
SMALL_BLOB = bytes((i * 11) & 0xFF for i in range(1000))
SYNTH_COMMON = [
    ("wifi", "ssid", "string", "TestNet-2G"),
    ("wifi", "password", "string", "FAKE-pass-0001"),
    ("wifi", "u8v", "u8", 200), ("wifi", "i8v", "i8", -128),
    ("wifi", "u16v", "u16", 65535), ("wifi", "i16v", "i16", -32768),
    ("wifi", "u32v", "u32", 4294967295), ("wifi", "i32v", "i32", -70),
    ("wifi", "u64v", "u64", 18446744073709551615), ("wifi", "i64v", "i64", -9000000000),
    ("wifi", "hexblob", "blob", bytes.fromhex("00112233445566778899aabbccddeeff")),
    ("other", "note", "string", "hello world"),
    ("other", "longtext", "string", "The quick brown fox jumps over the lazy dog. " * 20),
    ("other", "fileblob", "blob", SMALL_BLOB),
]
SYNTH = {
    "nvs-synth-v2": (2, SYNTH_COMMON + [("other", "bigblob", "blob", BIG_BLOB)]),
    "nvs-synth-v1": (1, SYNTH_COMMON),
}
SYNTH_SIZE = 0x6000
OFFICIAL_TYPES = {"uint8_t": "u8", "int8_t": "i8", "uint16_t": "u16", "int16_t": "i16", "uint32_t": "u32",
                  "int32_t": "i32", "uint64_t": "u64", "int64_t": "i64", "string": "string",
                  "blob_data": "blob", "blob": "blob"}


def write_synth_csv(work: str, name: str, items, container_dir: str):
    lines = ["key,type,encoding,value"]
    current = None
    for ns, key, typ, value in items:
        if ns != current:
            lines.append("%s,namespace,," % ns)
            current = ns
        if typ == "string":
            lines.append("%s,data,string,%s" % (key, value))
        elif typ == "blob" and len(value) <= 64:
            lines.append("%s,data,hex2bin,%s" % (key, value.hex()))
        elif typ == "blob":
            fn = "%s-%s.blob" % (name, key)
            with open(os.path.join(work, fn), "wb") as f:
                f.write(value)
            lines.append("%s,file,binary,%s/%s" % (key, container_dir, fn))
        else:
            lines.append("%s,data,%s,%d" % (key, typ, value))
    with open(os.path.join(work, name + ".csv"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ----------------------------------------------------------------------------- prepare

def bootloader_offset(buf: bytes):
    return next((o for o in E.BOOTLOADER_OFFSETS if o < len(buf) and buf[o] == E.ESP_IMAGE_MAGIC), None)


def plan(buf: bytes, with_nvs: bool):
    """[(kind, file name, lo, hi, label)] for the regions of this image that get cross-checked."""
    out = []
    pt = E.find_partition_table(buf)
    if pt is None:
        return pt, out
    out.append(("table", "table.bin", pt.offset, min(len(buf), pt.offset + E.PT_MAX_LEN), "partition table"))
    bl = bootloader_offset(buf)
    if bl is not None and pt.offset > bl:
        out.append(("image", "bootloader.bin", bl, pt.offset, "bootloader"))
    for p in pt.entries:
        hi = min(p.end, len(buf))
        if p.is_app and hi > p.offset and buf[p.offset] == E.ESP_IMAGE_MAGIC:
            out.append(("image", "app-%d.bin" % p.index, p.offset, hi, "app partition %s" % E.safe(p.name)))
        if with_nvs and p.type == 0x01 and p.subtype == 0x02 and hi > p.offset and not E.is_blank(buf[p.offset:hi]):
            out.append(("nvs", "nvs-real-%d.bin" % p.index, p.offset, hi, "NVS partition %s" % E.safe(p.name)))
    return pt, out


def cmd_prepare(args) -> int:
    with open(args.image, "rb") as f:
        buf = f.read()
    pt, regions = plan(buf, args.nvs)
    if pt is None:
        sys.stderr.write("no partition table in %s - nothing to cross-check\n" % args.image)
        return 1
    jobs = []
    for kind, fn, lo, hi, label in regions:
        path = os.path.join(args.work, fn)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(buf[lo:hi])
        jobs.append("%s %s" % (kind, fn))
        print("  prepared %-18s 0x%06x-0x%06x  %s" % (fn, lo, hi, label))
    for name, (version, items) in SYNTH.items():
        write_synth_csv(args.work, name, items, args.container_dir)
        jobs.append("nvsgen %s.csv %s.bin 0x%x %d" % (name, name, SYNTH_SIZE, version))
        jobs.append("nvs %s.bin" % name)
        print("  prepared %-18s NVS format v%d test vector: %d entries for Espressif's generator" % (name + ".csv", version, len(items)))
    with open(os.path.join(args.work, "jobs.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(jobs) + "\n")
    return 0


# ----------------------------------------------------------------------------- compare

class Tally:
    def __init__(self):
        self.match = 0
        self.mismatch = 0

    def row(self, what: str, ours, theirs, show: bool = True):
        ok = ours == theirs
        if ok:
            self.match += 1
            print("  MATCH     %-28s %s" % (what, ours if show else ""))
        else:
            self.mismatch += 1
            if show:
                print("  MISMATCH  %-28s ours: %s | Espressif: %s" % (what, ours, theirs))
            else:
                print("  MISMATCH  %-28s (values withheld)" % what)
        return ok

    def fail(self, text: str):
        self.mismatch += 1
        print("  FAILED    %s" % text)


def read(work: str, name: str) -> str:
    try:
        with open(os.path.join(work, name), "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def tool_rc(work: str, base: str):
    text = read(work, base + ".rc").strip()
    return int(text) if text.lstrip("-").isdigit() else None


def compare_table(work: str, pt, t: Tally):
    print()
    print("=== partition table: gen_esp32part.py vs espflash.py ===")
    rc = tool_rc(work, "table.bin")
    if rc != 0:
        t.fail("gen_esp32part.py exit status %s: %s" % (rc, E.safe(read(work, "table.bin.err").strip()[-300:])))
        if pt.md5_ok is False:
            print("            (espflash.py also says the MD5 is invalid)")
        return
    rows = []
    for line in read(work, "table.bin.out").splitlines():
        line = line.split("#", 1)[0].strip()
        cols = [c.strip() for c in line.split(",")]
        if len(cols) >= 5 and cols[0]:
            rows.append((cols[0], cols[1], cols[2], E._csv_number(cols[3]), E._csv_number(cols[4]),
                         cols[5] if len(cols) > 5 else ""))
    if pt.md5_present:
        # gen_esp32part.py exits non-zero on a wrong MD5, so exit status 0 means "valid"
        t.row("MD5 record", "valid" if pt.md5_ok else "INVALID", "valid")
    else:
        print("  note      the table has no MD5 record; gen_esp32part.py accepted it without one")
    t.row("number of entries", len(pt.entries), len(rows))
    for p, r in zip(pt.entries, rows):
        ours = (p.name, p.type_name, p.subtype_name, "0x%x" % p.offset, "0x%x" % p.size, p.flag_names.replace(",", ":"))
        theirs = (r[0], r[1], r[2], "0x%x" % r[3], "0x%x" % r[4], r[5])
        t.row("entry %d" % p.index, " ".join(x for x in ours if x), " ".join(x for x in theirs if x))


def parse_image_info(text: str) -> dict:
    def g(pat):
        m = re.search(pat, text, re.M)
        return m.group(1).strip() if m else None

    info = {
        "entry": g(r"^Entry point: (0x[0-9a-fA-F]+)"), "segments": g(r"^Segments: (\d+)"),
        "flash_size": g(r"^Flash size: (\S+)"), "flash_freq": g(r"^Flash freq: (\S+)"),
        "flash_mode": g(r"^Flash mode: (\S+)"), "chip_id": g(r"^Chip ID: (\d+)"),
        "project": g(r"^Project name: (.*)$"), "version": g(r"^App version: (.*)$"),
        "compile_time": g(r"^Compile time: (.*)$"), "elf_sha256": g(r"^ELF file SHA256: ([0-9a-f]+)"),
        "idf": g(r"^ESP-IDF: (.*)$"), "bootloader_version": g(r"^Bootloader version: (\d+)"),
    }
    m = re.search(r"^Checksum: (0x[0-9a-fA-F]+) \(([^)]*)\)", text, re.M)
    info["checksum"], info["checksum_state"] = (m.group(1).lower(), m.group(2)) if m else (None, None)
    m = re.search(r"^Validation hash: ([0-9a-f]{64}) \(([^)]*)\)", text, re.M)
    info["hash"], info["hash_state"] = (m.group(1), m.group(2)) if m else (None, None)
    info["rows"] = [(int(a), int(b, 16), int(c, 16), int(d, 16)) for a, b, c, d in
                    re.findall(r"^\s*(\d+)\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)", text, re.M)]
    return info


def compare_image(work: str, fn: str, label: str, buf: bytes, lo: int, hi: int, t: Tally):
    print()
    print("=== %s: esptool image-info vs espflash.py ===" % label)
    rc = tool_rc(work, fn)
    img = E.parse_image(buf, lo, hi)
    text = read(work, fn + ".out")
    if rc != 0 or "Entry point" not in text:
        ours = "valid" if img.valid else "invalid (%s)" % (img.error or "checksum/hash mismatch")
        tail = E.safe((text + read(work, fn + ".err")).strip()[-200:])
        if img.valid or img.error is None:
            t.fail("esptool image-info exit status %s (%s) but espflash.py says: %s" % (rc, tail, ours))
        else:
            t.match += 1
            print("  MATCH     both reject this region as an image (esptool exit %s; ours: %s)" % (rc, ours))
        return
    info = parse_image_info(text)
    h = img.header
    t.row("entry point", "0x%08x" % h.entry, info["entry"])
    t.row("segment count", str(h.segment_count), info["segments"])
    t.row("flash mode", h.spi_mode_name, info["flash_mode"])
    t.row("flash freq", h.spi_speed_name.replace(" MHz", "m"), info["flash_freq"])
    t.row("flash size", "%sMB" % h.flash_size_mb, info["flash_size"])
    t.row("chip id", str(h.chip_id), info["chip_id"])
    for s in img.segments:
        theirs = next((r for r in info["rows"] if r[0] == s.index), None)
        ours = "len 0x%x load 0x%08x file 0x%x" % (s.size, s.load_addr, s.file_off - lo - 8)
        t.row("segment %d" % s.index, ours, "len 0x%x load 0x%08x file 0x%x" % theirs[1:] if theirs else "missing")
    t.row("checksum", "0x%02x %s" % (img.checksum_stored, "valid" if img.checksum_ok else "invalid"),
          "%s %s" % (info["checksum"], "valid" if info["checksum_state"] == "valid" else "invalid"))
    if img.hash_stored is not None or info["hash"]:
        t.row("appended SHA-256", "%s %s" % (img.hash_stored.hex() if img.hash_stored else "none", "valid" if img.hash_ok else "invalid"),
              "%s %s" % (info["hash"], "valid" if info["hash_state"] == "valid" else "invalid"))
    app = E.parse_app_desc(buf, lo)
    bd = E.parse_bootloader_desc(buf, lo)
    if app is not None:
        t.row("project name", app.project_name, info["project"])
        t.row("app version", app.version, info["version"])
        t.row("compile time", "%s %s" % (app.date, app.time), info["compile_time"])
        t.row("ELF SHA-256", app.elf_sha256.hex(), info["elf_sha256"])
        t.row("ESP-IDF version", app.idf_ver, info["idf"])
    elif bd is not None:
        t.row("bootloader version", str(bd.version), info["bootloader_version"])
        t.row("ESP-IDF version", bd.idf_ver, info["idf"])
        t.row("compile time", bd.date_time, info["compile_time"])
    else:
        t.row("descriptor", "none", "none" if not (info["project"] or info["bootloader_version"]) else "present")


def official_nvs(text: str):
    """{(namespace, key): (type, value)} from nvs_tool.py -d minimal -f json. Blob chunks are joined
    in the order the tool lists them."""
    out = {}
    for e in json.loads(text):
        if not isinstance(e, dict) or e.get("state") != "Written":
            continue
        enc = OFFICIAL_TYPES.get(e.get("encoding"))
        if enc is None:
            continue
        ident = (e.get("namespace"), e.get("key"))
        data = e.get("data")
        if enc == "blob":
            chunk = base64.b64decode(data) if isinstance(data, str) else b""
            prev = out.get(ident)
            out[ident] = ("blob", (prev[1] if prev else b"") + chunk)
        else:
            out[ident] = (enc, data)
    return out


def compare_nvs(work: str, fn: str, label: str, data: bytes, t: Tally, expected=None):
    print()
    print("=== %s: nvs_tool.py%s vs espflash.py (values are compared, never printed) ===" % (
        label, " + nvs_partition_gen" if expected is not None else ""))
    dump = E.parse_nvs(data)
    ours = {(it.namespace, it.key): (it.type_name, it.value) for it in dump.items}
    bad = [it for it in dump.items if not it.complete]
    if dump.problems or bad:
        t.fail("espflash.py reports %d problems / %d incomplete entries" % (len(dump.problems), len(bad)))
    if expected is not None:
        want = {(ns, key): (typ, value) for ns, key, typ, value in expected}
        t.row("entries decoded from Espressif's image", len(ours), len(want))
        for ident in sorted(want):
            name = "%s/%s" % ident
            got = ours.get(ident)
            if got is None:
                t.fail("%s: missing from our decode" % name)
            else:
                t.row("%s (%s) = CSV value" % (name, want[ident][0]), got, want[ident], show=False)
    rc = tool_rc(work, fn)
    if rc != 0:
        t.fail("nvs_tool.py exit status %s on %s" % (rc, fn))
        return
    try:
        theirs = official_nvs(read(work, fn + ".out"))
    except ValueError:
        t.fail("nvs_tool.py output for %s is not JSON" % fn)
        return
    t.row("number of live entries", len(ours), len(theirs))
    for ident in sorted(set(ours) | set(theirs), key=lambda k: (str(k[0]), str(k[1]))):
        name = "%s/%s" % (E.safe(str(ident[0])), E.safe(str(ident[1])))
        a, b = ours.get(ident), theirs.get(ident)
        if a is None or b is None:
            t.fail("%s: only in %s" % (name, "nvs_tool.py" if a is None else "espflash.py"))
            continue
        if not t.row("%s (%s)" % (name, a[0]), a, b, show=False):
            la = len(a[1]) if hasattr(a[1], "__len__") else "-"
            lb = len(b[1]) if hasattr(b[1], "__len__") else "-"
            print("            type ours %s / theirs %s, length ours %s / theirs %s" % (a[0], b[0], la, lb))


def cmd_compare(args) -> int:
    with open(args.image, "rb") as f:
        buf = f.read()
    pt, regions = plan(buf, args.nvs)
    if pt is None:
        sys.stderr.write("no partition table in %s\n" % args.image)
        return 1
    t = Tally()
    env = dict(line.split("=", 1) for line in read(args.work, "tools.env").splitlines() if "=" in line)
    print("=== Espressif tools used (inside the container) ===")
    print("  ESP-IDF %s, esptool %s, esp_idf_nvs_partition_gen %s"
          % (E.safe(env.get("idf_git_describe", "?")), E.safe(env.get("esptool", "?")), E.safe(env.get("nvs_partition_gen", "?"))))
    for kind, fn, lo, hi, label in regions:
        if kind == "table":
            compare_table(args.work, pt, t)
        elif kind == "image":
            compare_image(args.work, fn, label, buf, lo, hi, t)
    for name, (version, items) in SYNTH.items():
        path = os.path.join(args.work, name + ".bin")
        if tool_rc(args.work, name + ".csv") != 0 or not os.path.isfile(path):
            print()
            t.fail("nvs_partition_gen could not build %s: %s" % (name, E.safe(read(args.work, name + ".csv.err").strip()[-300:])))
            continue
        with open(path, "rb") as f:
            compare_nvs(args.work, name + ".bin", "synthetic NVS, format v%d" % version, f.read(), t, expected=items)
    for kind, fn, lo, hi, label in regions:
        if kind == "nvs":
            try:
                compare_nvs(args.work, fn, label + " of the image", buf[lo:hi], t)
            except Exception as e:          # never let an error message carry NVS contents
                t.fail("comparison of %s aborted (%s)" % (fn, type(e).__name__))
    if not args.nvs:
        print()
        print("  (the image's own NVS partition was not sent to nvs_tool.py; add --nvs to include it)")
    print()
    print("=== result ===")
    print("  %d facts match, %d mismatches/failures" % (t.match, t.mismatch))
    return 4 if t.mismatch else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("image"); p.add_argument("work")
    p.add_argument("--container-dir", required=True, help="path of WORKDIR as seen inside the container")
    p.add_argument("--nvs", action="store_true")
    p.set_defaults(fn=cmd_prepare)
    p = sub.add_parser("compare")
    p.add_argument("image"); p.add_argument("work")
    p.add_argument("--nvs", action="store_true")
    p.set_defaults(fn=cmd_compare)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
