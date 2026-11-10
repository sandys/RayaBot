#!/usr/bin/env python3
"""compare_images.py — the engine of scripts/32-compare-images.sh.

    python3 -I -B compare_images.py A.bin B.bin

Compares two raw flash images region by region. The regions come from the partition
table found in A: the bootloader area in front of the table, the table's own sector,
every partition, any gap between them, and whatever follows the last partition.

For each region one of:
  identical              every byte that exists in both files is equal
  DIFFERS                with the absolute offset of the first difference (and the offset
                         inside the region), how many bytes differ and in how many 4 KiB
                         sectors; if the differences sit in at most 12 places, their offset
                         ranges are listed
  beyond end of file X   the region starts after the end of A and/or B: nothing to compare
A region that only partly exists in one file is compared over the common part, and the
rest is described ("B has 0x... more bytes here: blank / N non-0xFF").

Only offsets, counts and the public application descriptor (project/version/build time)
are printed - never image contents, so the output is safe to keep even for device dumps.

Exit status: 0 = nothing differs in what could be compared, 2 = at least one region
differs, 1 = could not run (unreadable file, no partition table in A).
"""

import hashlib
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import espflash as E  # noqa: E402

SECTOR = E.SECTOR
VOLATILE = {(0x01, 0x02): "NVS is rewritten by the firmware at run time",
            (0x01, 0x00): "otadata is rewritten on OTA updates and rollback bookkeeping",
            (0x01, 0x03): "core dumps are written at run time"}


def hx(n: int) -> str:
    return "0x%06x" % n


def first_difference(a: bytes, b: bytes) -> int:
    """Index of the first differing byte of two equally long byte strings (they do differ)."""
    n = len(a)
    for blk in range(0, n, SECTOR):
        if a[blk:blk + SECTOR] != b[blk:blk + SECTOR]:
            for i in range(blk, min(blk + SECTOR, n)):
                if a[i] != b[i]:
                    return i
    return -1


def count_differences(a: bytes, b: bytes):
    """(differing bytes, differing 4 KiB sectors, sectors) for two equally long byte strings."""
    n = len(a)
    x = int.from_bytes(a, "little") ^ int.from_bytes(b, "little")
    nbytes = n - x.to_bytes(n, "little").count(0)
    sectors = (n + SECTOR - 1) // SECTOR
    dirty = sum(1 for blk in range(0, n, SECTOR) if a[blk:blk + SECTOR] != b[blk:blk + SECTOR])
    return nbytes, dirty, sectors


def differing_ranges(a: bytes, b: bytes, limit: int = 12):
    """[(first, last)] index ranges that differ, neighbours closer than 16 bytes merged.
    None if there are more than `limit` of them (then the list would say nothing)."""
    n = len(a)
    x = (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(n, "little")
    runs = []
    for blk in range(0, n, SECTOR):
        chunk = x[blk:blk + SECTOR]
        if not any(chunk):
            continue
        for i, v in enumerate(chunk):
            if v:
                pos = blk + i
                if runs and pos - runs[-1][1] <= 16:
                    runs[-1][1] = pos
                else:
                    runs.append([pos, pos])
                    if len(runs) > limit:
                        return None
    return [(lo, hi) for lo, hi in runs]


def fill(buf: bytes) -> str:
    if not buf:
        return "nothing"
    used = len(buf) - buf.count(0xFF)
    return "blank (0xFF)" if used == 0 else "%d non-0xFF bytes" % used


def app_line(buf: bytes, off: int) -> str:
    d = E.parse_app_desc(buf, off) if off < len(buf) and buf[off] == E.ESP_IMAGE_MAGIC else None
    if d is None:
        return "no app descriptor"
    return "%s %s, built %s %s, ESP-IDF %s" % (E.safe(d.project_name), E.safe(d.version), E.safe(d.date),
                                               E.safe(d.time), E.safe(d.idf_ver))


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1].startswith("-"):
        sys.stderr.write("usage: compare_images.py A.bin B.bin\n")
        return 1
    paths = sys.argv[1:3]
    bufs = []
    for p in paths:
        try:
            with open(p, "rb") as f:
                bufs.append(f.read())
        except OSError as e:
            sys.stderr.write("cannot read %s: %s\n" % (p, e))
            return 1
    a, b = bufs
    print("=== images ===")
    for tag, p, buf in (("A", paths[0], a), ("B", paths[1], b)):
        print("  %s: %s" % (tag, p))
        print("     %d bytes (%s), sha256 %s" % (len(buf), E.fmt_size(len(buf)), hashlib.sha256(buf).hexdigest()))
    pt = E.find_partition_table(a)
    if pt is None or not pt.entries:
        sys.stderr.write("A has no partition table (looked at 0x8000 and every 4 KiB boundary below 1 MiB).\n"
                         "The regions are taken from A: put the image that has a partition table first.\n")
        return 1
    print("  regions: partition table of A at %s (%d partitions, MD5 %s)"
          % (hx(pt.offset), len(pt.entries), {True: "valid", False: "INVALID", None: "absent"}[pt.md5_ok]))

    # region list: name, lo, hi, partition (or None)
    regions = [("bootloader", 0, pt.offset, None), ("partition-table", pt.offset, pt.offset + SECTOR, None)]
    pos = pt.offset + SECTOR
    for p in sorted(pt.entries, key=lambda q: q.offset):
        if p.offset > pos:
            regions.append(("(unallocated)", pos, p.offset, None))
        if p.offset < pos:
            print("  note: partition %s overlaps the region before it; compared as listed" % E.safe(p.name))
        regions.append((p.name, p.offset, p.end, p))
        pos = max(pos, p.end)
    top = max(len(a), len(b))
    if top > pos:
        regions.append(("(after last)", pos, top, None))

    print()
    print("=== comparison ===")
    print("  %-16s %-9s %-9s %s" % ("region", "offset", "size", "result"))
    identical, differ, skipped = [], [], []
    for name, lo, hi, part in regions:
        a_hi, b_hi = min(hi, len(a)), min(hi, len(b))
        common = min(a_hi, b_hi) - lo
        label = "  %-16s %-9s %-9s " % (E.safe(name)[:16], hx(lo), hx(hi - lo))
        pad = " " * len(label)
        if common <= 0:
            who = [t for t, end in (("A", a_hi), ("B", b_hi)) if end <= lo]
            extra = ""
            if "A" in who and "B" not in who:
                extra = "; B holds %s there" % fill(b[lo:b_hi])
            elif "B" in who and "A" not in who:
                extra = "; A holds %s there" % fill(a[lo:a_hi])
            print(label + "beyond end of file %s - not compared%s" % (" and ".join(who), extra))
            skipped.append(name)
            continue
        sa, sb = a[lo:lo + common], b[lo:lo + common]
        scope = "" if common == hi - lo else " in the first 0x%x bytes (all that both files have)" % common
        if sa == sb:
            print(label + "identical" + scope)
            identical.append(name)
        else:
            i = first_difference(sa, sb)
            nbytes, dirty, sectors = count_differences(sa, sb)
            print(label + "DIFFERS: first difference at %s (+0x%x), %d bytes differ in %d of %d sectors%s"
                  % (hx(lo + i), i, nbytes, dirty, sectors, scope))
            differ.append(name)
            hints = []
            runs = differing_ranges(sa, sb)
            if runs:
                hints.append("differing ranges: " + ", ".join(
                    hx(lo + r0) if r0 == r1 else "%s-%s" % (hx(lo + r0), hx(lo + r1)) for r0, r1 in runs))
            if E.is_blank(sa):
                hints.append("A is blank (0xFF) here, B holds %s" % fill(sb))
            elif E.is_blank(sb):
                hints.append("B is blank (0xFF) here, A holds %s" % fill(sa))
            if part is not None and (part.type, part.subtype) in VOLATILE:
                hints.append("expected after the device has run: %s" % VOLATILE[(part.type, part.subtype)])
            if name == "partition-table":
                hints.append("B has a different partition table - the regions in this report are A's")
            for h in hints:
                print(pad + h)
            if part is not None and part.is_app:
                print(pad + "A: %s" % app_line(a, lo))
                print(pad + "B: %s" % app_line(b, lo))
        if a_hi != b_hi:
            longer, buf, start, end = ("B", b, a_hi, b_hi) if b_hi > a_hi else ("A", a, b_hi, a_hi)
            shorter = "A" if longer == "B" else "B"
            print(pad + "beyond end of file %s: %s has 0x%x more bytes of this region: %s"
                  % (shorter, longer, end - start, fill(buf[start:end])))

    print()
    print("=== summary ===")
    print("  identical:      %d regions%s" % (len(identical), (" (" + ", ".join(E.safe(n) for n in identical) + ")") if identical else ""))
    print("  differ:         %d regions%s" % (len(differ), (" (" + ", ".join(E.safe(n) for n in differ) + ")") if differ else ""))
    print("  not compared:   %d regions%s" % (len(skipped), (" (" + ", ".join(E.safe(n) for n in skipped) + ")") if skipped else ""))
    if len(a) == len(b):
        print("  whole files:    %s" % ("byte-identical" if a == b else "same size, contents differ"))
    else:
        print("  whole files:    different sizes (A %d bytes, B %d bytes)" % (len(a), len(b)))
    if differ:
        print("  result:         DIFFERENCES FOUND")
        return 2
    print("  result:         no differences in the %d regions that exist in both files" % len(identical))
    return 0


if __name__ == "__main__":
    sys.exit(main())
