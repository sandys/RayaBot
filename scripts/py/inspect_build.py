#!/usr/bin/env python3
"""inspect_build.py - read ESP-IDF build artifacts without ESP-IDF or esptool (Python stdlib only).

The Python half of scripts/12-inspect-build.sh (and the final check of
scripts/11-build-firmware.sh). It runs on the WSL host, needs nothing but python3,
and never touches a serial port: it only reads files.

    inspect_build.py flash-files <flasher_args.json>   # "offset<TAB>relative-path" per line, by offset
    inspect_build.py inspect <artifact-dir>            # full report; exit 1 if anything is wrong
    inspect_build.py config-delta <old> <new>          # sdkconfig lines that turn <old> into <new>

What "inspect" reads in <artifact-dir> (= out/<board>/<label>/)
    flasher_args.json   written by the ESP-IDF build: flash mode/freq/size and the list of
                        offset -> file. This is the authority for what gets flashed where.
    the partition table (the file flasher_args.json maps to the partition-table offset)
    every listed image, the application image's descriptor, merged-binary.bin, SHA256SUMS

What it checks (each failure is listed and makes the exit status 1)
    - every file named in flasher_args.json exists, plus merged-binary.bin, flash_args,
      build-info.txt and SHA256SUMS
    - the partition table parses, its MD5 is right, partitions do not overlap and end
      inside the flash size the build was configured for; our decode agrees with the one
      ESP-IDF's gen_esp32part.py made inside the container at build time (partition-table.csv)
    - every file starts at the start of a region (bootloader area, partition table sector,
      or a partition) and is not larger than that region
    - the application is a valid image for the expected chip: header magic, XOR checksum,
      appended SHA-256, application descriptor magic; debug/<app>.elf, if present, is the
      ELF the image was made from (its SHA-256 is stored in the descriptor)
    - merged-binary.bin contains every file byte-for-byte at its offset, 0xFF in between
    - every file still has the SHA-256 recorded in SHA256SUMS

Binary formats (ESP-IDF: components/partition_table/gen_esp32part.py,
components/bootloader_support/include/esp_app_format.h, components/esp_app_format/include/esp_app_desc.h)
    partition entry, 32 bytes: magic AA 50 | type u8 | subtype u8 | offset u32 | size u32 | name[16] | flags u32
    table terminator:          magic EB EB | FF x14 | md5[16] of all entries before it, then FF padding
    image header, 24 bytes:    E9 | segments u8 | spi mode u8 | (size<<4 | freq) u8 | entry u32 | wp u8 |
                               drv[3] | chip id u16 | min rev u8 | min rev full u16 | max rev full u16 |
                               reserved[4] | hash appended u8
    then per segment:          load address u32 | length u32 | data
    then padding so that the 1-byte XOR checksum (seed 0xEF, over all segment data) ends a
    16-byte block, then (if "hash appended") the SHA-256 of everything before it.
    application descriptor:    256 bytes at file offset 32 (start of the first segment):
                               magic ABCD5432 | secure version | reserved[8] | version[32] |
                               project name[32] | time[16] | date[16] | idf version[32] | ELF sha256[32] | ...
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

PT_ENTRY = struct.Struct("<2sBBII16sI")
PT_MAGIC = b"\xaa\x50"
PT_MD5_MAGIC = b"\xeb\xeb"
PT_SECTOR = 0x1000   # the table lives in one flash sector
PT_MAX_LEN = 0xC00   # ... of which the entries (incl. MD5) may use this much

TYPE_NAMES = {0x00: "app", 0x01: "data", 0x02: "bootloader", 0x03: "partition_table"}
APP_SUBTYPES = {0x00: "factory", 0x20: "test", **{0x10 + i: f"ota_{i}" for i in range(16)}}
DATA_SUBTYPES = {
    0x00: "ota", 0x01: "phy", 0x02: "nvs", 0x03: "coredump", 0x04: "nvs_keys",
    0x05: "efuse", 0x06: "undefined", 0x80: "esphttpd", 0x81: "fat", 0x82: "spiffs",
    0x83: "littlefs", 0x90: "tee_ota", 0x91: "tee_sec_stg",
}

IMG_HEADER = struct.Struct("<BBBBIB3sHBHH4sB")
IMG_MAGIC = 0xE9
APP_DESC_OFFSET = IMG_HEADER.size + 8
APP_DESC_MAGIC = 0xABCD5432
BOOTLOADER_DESC_MAGIC = 0x50

CHIP_IDS = {
    0x0000: "esp32", 0x0002: "esp32s2", 0x0005: "esp32c3", 0x0009: "esp32s3",
    0x000C: "esp32c2", 0x000D: "esp32c6", 0x0010: "esp32h2", 0x0012: "esp32p4",
    0x0014: "esp32c61", 0x0017: "esp32c5", 0x0020: "esp32s31",
}
SPI_MODES = {0: "qio", 1: "qout", 2: "dio", 3: "dout", 4: "fast_read", 5: "slow_read"}
SPI_SIZES = {0: "1MB", 1: "2MB", 2: "4MB", 3: "8MB", 4: "16MB", 5: "32MB", 6: "64MB", 7: "128MB"}
SPI_FREQS = {0x0: "40m", 0x1: "26m", 0x2: "20m", 0xF: "80m"}


class Problems:
    """Collects everything that must make the exit status non-zero."""

    def __init__(self):
        self.items = []

    def add(self, text):
        self.items.append(text)
        return text


def human(n):
    if n >= 1 << 20:
        return f"{n / (1 << 20):.2f} MiB" if n % (1 << 20) else f"{n >> 20} MiB"
    if n >= 1 << 10:
        return f"{n / (1 << 10):.1f} KiB" if n % (1 << 10) else f"{n >> 10} KiB"
    return f"{n} B"


def cstr(raw):
    return raw.split(b"\0", 1)[0].decode("utf-8", errors="replace")


def parse_size(text):
    """'16MB' -> bytes (flash_size as written in flasher_args.json)."""
    text = text.strip().upper()
    for suffix, factor in (("MB", 1 << 20), ("KB", 1 << 10), ("M", 1 << 20), ("K", 1 << 10)):
        if text.endswith(suffix):
            return int(text[: -len(suffix)]) * factor
    return int(text, 0)


# ----------------------------------------------------------------------------- flasher_args


def load_flasher_args(path):
    with open(path, encoding="utf-8") as handle:
        args = json.load(handle)
    files = []
    for offset, name in args.get("flash_files", {}).items():
        if Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError(
                f"flasher_args.json lists {name!r}: only paths inside the build directory are supported"
            )
        files.append((int(offset, 0), name))
    if not files:
        raise ValueError("flasher_args.json has no flash_files")
    return args, sorted(files)


def role_offsets(args):
    """{'bootloader': 0x0, 'partition-table': 0x8000, 'app': 0x20000, ...} from the per-role entries."""
    roles = {}
    for key, value in args.items():
        if isinstance(value, dict) and "offset" in value and "file" in value:
            roles[key] = (int(value["offset"], 0), value["file"])
    return roles


# ----------------------------------------------------------------------------- partition table


class Partition:
    def __init__(self, name, ptype, subtype, offset, size, flags):
        self.name, self.ptype, self.subtype = name, ptype, subtype
        self.offset, self.size, self.flags = offset, size, flags

    @property
    def end(self):
        return self.offset + self.size

    @property
    def type_name(self):
        return TYPE_NAMES.get(self.ptype, f"0x{self.ptype:02x}")

    @property
    def subtype_name(self):
        table = APP_SUBTYPES if self.ptype == 0x00 else DATA_SUBTYPES if self.ptype == 0x01 else {}
        return table.get(self.subtype, f"0x{self.subtype:02x}")

    @property
    def flag_names(self):
        names = [name for bit, name in ((1, "encrypted"), (2, "readonly")) if self.flags & bit]
        return ",".join(names) if names else "-"


def parse_partition_table(data):
    """-> (partitions, md5_ok) where md5_ok is None when the table carries no MD5."""
    partitions, md5_ok = [], None
    for pos in range(0, len(data) - PT_ENTRY.size + 1, PT_ENTRY.size):
        raw = data[pos:pos + PT_ENTRY.size]
        if raw == b"\xff" * PT_ENTRY.size:
            break
        if raw[:2] == PT_MD5_MAGIC:
            md5_ok = hashlib.md5(data[:pos]).digest() == raw[16:32]
            continue
        magic, ptype, subtype, offset, size, name, flags = PT_ENTRY.unpack(raw)
        if magic != PT_MAGIC:
            raise ValueError(f"partition table: bad entry magic {magic.hex()} at byte {pos}")
        partitions.append(Partition(cstr(name), ptype, subtype, offset, size, flags))
    if not partitions:
        raise ValueError("partition table: no entries")
    return partitions, md5_ok


def parse_idf_partition_csv(text):
    """The CSV that ESP-IDF's gen_esp32part.py prints for a binary table -> [(name, offset, size)]."""
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = [field.strip() for field in line.split(",")]
        if len(fields) < 5:
            raise ValueError(f"partition-table.csv: cannot read line {line!r}")
        rows.append((fields[0], parse_size(fields[3]), parse_size(fields[4])))
    return rows


# ----------------------------------------------------------------------------- images


class Image:
    """An ESP application/bootloader image: header, segments, checksum, appended hash."""

    def __init__(self, data):
        if len(data) < IMG_HEADER.size + 8:
            raise ValueError("file is too short to be an ESP image")
        (magic, self.segment_count, spi_mode, speed_size, self.entry, _wp, _drv, self.chip_id,
         _min_rev, self.min_rev_full, self.max_rev_full, _reserved, hash_appended) = IMG_HEADER.unpack_from(data)
        if magic != IMG_MAGIC:
            raise ValueError(f"not an ESP image: first byte is 0x{magic:02x}, expected 0xe9")
        self.flash_mode = SPI_MODES.get(spi_mode, f"0x{spi_mode:x}")
        self.flash_size = SPI_SIZES.get(speed_size >> 4, f"0x{speed_size >> 4:x}")
        self.flash_freq = SPI_FREQS.get(speed_size & 0xF, f"0x{speed_size & 0xF:x}")
        self.hash_appended = hash_appended == 1

        pos, checksum, self.segments = IMG_HEADER.size, 0xEF, []
        for _ in range(self.segment_count):
            if pos + 8 > len(data):
                raise ValueError("image is truncated inside a segment header")
            load_addr, length = struct.unpack_from("<II", data, pos)
            pos += 8
            if pos + length > len(data):
                raise ValueError("image is truncated inside segment data")
            segment = data[pos:pos + length]
            # XOR of all bytes == XOR of the bytes of the XOR of all 8-byte words: fast in pure Python.
            padded = segment + b"\0" * (-len(segment) % 8)
            acc = 0
            for (word,) in struct.iter_unpack("<Q", padded):
                acc ^= word
            for shift in range(0, 64, 8):
                checksum ^= (acc >> shift) & 0xFF
            self.segments.append((load_addr, length))
            pos += length
        checksum_pos = pos + (15 - pos % 16)
        if checksum_pos >= len(data):
            raise ValueError("image is truncated before its checksum byte")
        self.checksum_ok = data[checksum_pos] == checksum
        self.body_end = checksum_pos + 1
        self.hash_ok = None
        self.image_end = self.body_end
        if self.hash_appended:
            stored = data[self.body_end:self.body_end + 32]
            self.hash_ok = len(stored) == 32 and hashlib.sha256(data[:self.body_end]).digest() == stored
            self.image_end = self.body_end + 32
        self.chip = CHIP_IDS.get(self.chip_id, f"unknown(0x{self.chip_id:04x})")

    @staticmethod
    def rev(full):
        return f"v{full // 100}.{full % 100}"


def app_descriptor(data):
    raw = data[APP_DESC_OFFSET:APP_DESC_OFFSET + 256]
    if len(raw) < 256 or struct.unpack_from("<I", raw)[0] != APP_DESC_MAGIC:
        raise ValueError("no application descriptor (magic 0xABCD5432) at file offset 32")
    return {
        "secure_version": struct.unpack_from("<I", raw, 4)[0],
        "version": cstr(raw[16:48]),
        "project_name": cstr(raw[48:80]),
        "time": cstr(raw[80:96]),
        "date": cstr(raw[96:112]),
        "idf_ver": cstr(raw[112:144]),
        "elf_sha256": raw[144:176].hex(),
    }


def bootloader_descriptor(data):
    """esp_bootloader_desc_t at the start of the first segment, or None on images without one."""
    raw = data[APP_DESC_OFFSET:APP_DESC_OFFSET + 80]
    if len(raw) < 80 or raw[0] != BOOTLOADER_DESC_MAGIC:
        return None
    return {
        "version": struct.unpack_from("<I", raw, 4)[0],
        "idf_ver": cstr(raw[8:40]),
        "date_time": cstr(raw[40:64]),
    }


# ----------------------------------------------------------------------------- report


def table(rows, indent="  "):
    widths = [max(len(str(row[col])) for row in rows) for col in range(len(rows[0]))]
    for row in rows:
        print((indent + "  ".join(str(cell).ljust(width) for cell, width in zip(row, widths))).rstrip())


def read_build_info(path):
    """The 'key: value' lines of build-info.txt (first occurrence wins)."""
    info = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith(("#", "[", " ")) or ":" not in line:
            continue
        key, _, value = line.partition(":")
        info.setdefault(key.strip(), value.strip())
    return info


def inspect(root):
    problems = Problems()
    root = Path(root)
    if not root.is_dir():
        print(f"ERROR: no such build directory: {root}")
        return 1
    print(f"=== build artifacts: {root} ===")

    def need(name):
        path = root / name
        if not path.is_file():
            problems.add(f"expected file is missing: {name}")
            return None
        return path

    info_path = need("build-info.txt")
    if info_path:
        info = read_build_info(info_path)
        for key in ("board", "variant", "label", "stock build", "sdkconfig append", "built",
                    "source ref", "source commit", "working tree", "idf version",
                    "docker image", "image digest"):
            if key in info:
                print(f"  {key + ':':<17} {info[key]}")
    need("flash_args")

    fa_path = need("flasher_args.json")
    if not fa_path:
        return finish(problems)
    try:
        args, files = load_flasher_args(fa_path)
    except (ValueError, json.JSONDecodeError) as error:
        problems.add(f"flasher_args.json: {error}")
        return finish(problems)
    roles = role_offsets(args)
    settings = args.get("flash_settings", {})
    extra = args.get("extra_esptool_args", {})
    chip = extra.get("chip", "?")

    print("\n=== flash settings (flasher_args.json) ===")
    print(f"  chip {chip}, flash mode {settings.get('flash_mode', '?')}, "
          f"freq {settings.get('flash_freq', '?')}, size {settings.get('flash_size', '?')}")
    print(f"  esptool: before={extra.get('before', '?')} after={extra.get('after', '?')} "
          f"stub={extra.get('stub', '?')}")
    flash_bytes = None
    try:
        flash_bytes = parse_size(settings["flash_size"])
    except (KeyError, ValueError):
        problems.add("flasher_args.json: flash_settings.flash_size is missing or unreadable")

    # ---- partition table
    if "partition-table" not in roles:
        problems.add("flasher_args.json has no partition-table entry")
        return finish(problems)
    pt_offset, pt_file = roles["partition-table"]
    boot_offset = roles["bootloader"][0] if "bootloader" in roles else None
    partitions, md5_ok = [], None
    pt_path = need(pt_file)
    if pt_path:
        try:
            partitions, md5_ok = parse_partition_table(pt_path.read_bytes())
        except ValueError as error:
            problems.add(str(error))
    if not partitions:
        return finish(problems)
    md5_text = {True: "MD5 ok", False: "MD5 MISMATCH", None: "no MD5"}[md5_ok]
    if md5_ok is False:
        problems.add("partition table: MD5 mismatch")

    by_offset = {offset: name for offset, name in files}
    print(f"\n=== partition table ({pt_file} at 0x{pt_offset:x}, {len(partitions)} entries, {md5_text}) ===")
    rows = [("name", "type", "subtype", "offset", "size", "", "end", "flags", "this build writes")]
    if boot_offset is not None:
        rows.append(("(bootloader)", "-", "-", f"0x{boot_offset:06x}", f"0x{pt_offset - boot_offset:06x}",
                     human(pt_offset - boot_offset), f"0x{pt_offset:06x}", "-", by_offset.get(boot_offset, "-")))
    rows.append(("(part. table)", "-", "-", f"0x{pt_offset:06x}", f"0x{PT_SECTOR:06x}", human(PT_SECTOR),
                 f"0x{pt_offset + PT_SECTOR:06x}", "-", by_offset.get(pt_offset, "-")))
    cursor = pt_offset + PT_SECTOR
    for part in sorted(partitions, key=lambda p: p.offset):
        if part.offset > cursor:
            rows.append(("(unused)", "-", "-", f"0x{cursor:06x}", f"0x{part.offset - cursor:06x}",
                         human(part.offset - cursor), f"0x{part.offset:06x}", "-", "-"))
        elif part.offset < cursor:
            problems.add(f"partition {part.name} at 0x{part.offset:x} overlaps the region before it "
                         f"(which ends at 0x{cursor:x})")
        rows.append((part.name, part.type_name, part.subtype_name, f"0x{part.offset:06x}",
                     f"0x{part.size:06x}", human(part.size), f"0x{part.end:06x}", part.flag_names,
                     by_offset.get(part.offset, "-")))
        cursor = max(cursor, part.end)
    table(rows)
    csv_path = need("partition-table.csv")
    if csv_path:
        try:
            idf_rows = parse_idf_partition_csv(csv_path.read_text(encoding="utf-8"))
            if idf_rows == [(p.name, p.offset, p.size) for p in partitions]:
                print("  matches ESP-IDF's own decode of the same file (partition-table.csv, gen_esp32part.py)")
            else:
                problems.add("partition table: our decode differs from ESP-IDF's partition-table.csv")
        except ValueError as error:
            problems.add(str(error))
    if flash_bytes is not None:
        if cursor > flash_bytes:
            problems.add(f"partition table ends at 0x{cursor:x}, beyond the {settings['flash_size']} flash")
            print(f"  table ends at 0x{cursor:x} - BEYOND the {settings['flash_size']} flash (0x{flash_bytes:x})")
        else:
            print(f"  table ends at 0x{cursor:x}; flash is {settings['flash_size']} (0x{flash_bytes:x}): "
                  f"{human(flash_bytes - cursor)} unallocated at the end")

    # ---- flash files: where each goes and how full its region is
    print("\n=== flash files (offset -> file, from flasher_args.json) ===")
    rows = [("offset", "file", "bytes", "", "region", "capacity", "used", "free")]
    contents, previous_end, previous_name = {}, 0, None
    for offset, name in files:
        path = need(name)
        if path is None:
            rows.append((f"0x{offset:06x}", name, "MISSING", "", "", "", "", ""))
            continue
        data = path.read_bytes()
        contents[offset] = (name, data)
        size = len(data)
        if offset < previous_end:
            problems.add(f"{name} at 0x{offset:x} overlaps {previous_name}, which ends at 0x{previous_end:x}")
        previous_end, previous_name = offset + size, name

        if offset == boot_offset:
            region, capacity = "(bootloader)", pt_offset - boot_offset
        elif offset == pt_offset:
            region, capacity = "(part. table)", PT_SECTOR
            if size > PT_MAX_LEN:
                problems.add(f"{name}: {size} bytes, a partition table may be at most {PT_MAX_LEN}")
        else:
            part = next((p for p in partitions if p.offset <= offset < p.end), None)
            if part is None:
                problems.add(f"{name} is flashed at 0x{offset:x}, which is not inside any partition")
                rows.append((f"0x{offset:06x}", name, size, human(size), "NONE", "", "", ""))
                continue
            region, capacity = part.name, part.end - offset
            if offset != part.offset:
                problems.add(f"{name} is flashed at 0x{offset:x}, not at the start of partition "
                             f"{part.name} (0x{part.offset:x})")
        if size > capacity:
            problems.add(f"{name} does not fit: {size} bytes into {region} of {capacity} bytes "
                         f"({size - capacity} too many)")
            rows.append((f"0x{offset:06x}", name, size, human(size), region, human(capacity),
                         f"{100 * size / capacity:.1f}%", "DOES NOT FIT"))
        else:
            rows.append((f"0x{offset:06x}", name, size, human(size), region, human(capacity),
                         f"{100 * size / capacity:.1f}%", human(capacity - size)))
    table(rows)

    # ---- bootloader + application images
    if boot_offset in contents:
        name, data = contents[boot_offset]
        print(f"\n=== bootloader image ({name}) ===")
        try:
            image = Image(data)
            print(f"  chip {image.chip}; header says flash mode {image.flash_mode}, freq {image.flash_freq}, "
                  f"size {image.flash_size}  <- what the ROM loader uses to read the rest of flash")
            desc = bootloader_descriptor(data)
            if desc:
                print(f"  ESP-IDF {desc['idf_ver']}, built {desc['date_time']}, bootloader version {desc['version']}")
            print(f"  {image.segment_count} segments, checksum {'ok' if image.checksum_ok else 'BAD'}, "
                  f"sha256 {'ok' if image.hash_ok else 'BAD' if image.hash_ok is False else 'not appended'}")
            if not image.checksum_ok or image.hash_ok is False:
                problems.add(f"{name}: image checksum/hash is wrong")
            if chip != "?" and image.chip != chip:
                problems.add(f"{name} is built for {image.chip}, flasher_args.json says {chip}")
            if settings.get("flash_size") and image.flash_size != settings["flash_size"]:
                problems.add(f"{name}: header flash size {image.flash_size} != configured {settings['flash_size']}")
        except ValueError as error:
            problems.add(f"{name}: {error}")

    if "app" not in roles:
        problems.add("flasher_args.json has no app entry")
    elif roles["app"][0] in contents:
        name, data = contents[roles["app"][0]]
        print(f"\n=== application descriptor ({name}) ===")
        try:
            image = Image(data)
            desc = app_descriptor(data)
            print(f"  project name:  {desc['project_name']}")
            print(f"  version:       {desc['version']}")
            print(f"  IDF version:   {desc['idf_ver']}")
            print(f"  build date:    {desc['date']} {desc['time']}  (compiler clock inside the container: UTC)")
            print(f"  ELF sha256:    {desc['elf_sha256']}")
            print(f"  secure ver.:   {desc['secure_version']}")
            print(f"  image:         chip {image.chip} (id 0x{image.chip_id:04x}), {image.segment_count} segments, "
                  f"entry 0x{image.entry:08x}, chip rev {image.rev(image.min_rev_full)}..{image.rev(image.max_rev_full)}")
            print(f"  integrity:     checksum {'ok' if image.checksum_ok else 'BAD'}, "
                  f"appended sha256 {'ok' if image.hash_ok else 'BAD' if image.hash_ok is False else 'absent'}, "
                  f"image length {image.image_end} of {len(data)} file bytes")
            if not image.checksum_ok or image.hash_ok is False:
                problems.add(f"{name}: image checksum/hash is wrong")
            if chip != "?" and image.chip != chip:
                problems.add(f"{name} is built for {image.chip}, flasher_args.json says {chip}")
            part = next((p for p in partitions if p.offset == roles["app"][0]), None)
            if part is not None and part.ptype != 0x00:
                problems.add(f"{name} is flashed into {part.name}, which is not an app partition")
            # The descriptor carries the SHA-256 of the ELF the image was made from, so the
            # ELF kept for decoding backtraces can be proven to be the matching one.
            elf = root / "debug" / (Path(name).stem + ".elf")
            if elf.is_file():
                if hashlib.sha256(elf.read_bytes()).hexdigest() == desc["elf_sha256"]:
                    print(f"  debug ELF:     debug/{elf.name} is the ELF this image was made from (sha256 matches)")
                else:
                    problems.add(f"debug/{elf.name} is not the ELF that {name} was made from (sha256 differs)")
        except ValueError as error:
            problems.add(f"{name}: {error}")

    # ---- merged image
    merged_path = need("merged-binary.bin")
    if merged_path:
        merged = merged_path.read_bytes()
        print("\n=== merged image (merged-binary.bin, flash at 0x0) ===")
        base = min(contents) if contents else 0
        mismatched, covered = [], []
        for offset, (name, data) in sorted(contents.items()):
            start = offset - base
            if merged[start:start + len(data)] != data:
                mismatched.append(name)
            covered.append((start, start + len(data)))
        gaps_clean, cursor = True, 0
        for start, end in covered:
            if merged[cursor:start].strip(b"\xff"):
                gaps_clean = False
            cursor = max(cursor, end)
        tail_clean = not merged[cursor:].strip(b"\xff")
        print(f"  {len(merged)} bytes ({human(len(merged))}), covers 0x{base:x}..0x{base + len(merged):x}")
        print(f"  parts found at their offsets: {len(contents) - len(mismatched)}/{len(contents)}; "
              f"padding between parts is 0xFF: {'yes' if gaps_clean and tail_clean else 'NO'}")
        if base != 0:
            problems.add(f"merged-binary.bin would have to be flashed at 0x{base:x}, not 0x0")
        for name in mismatched:
            problems.add(f"merged-binary.bin does not contain {name} at its offset")
        if not (gaps_clean and tail_clean):
            problems.add("merged-binary.bin has unexpected data between the parts")
        if flash_bytes is not None and len(merged) > flash_bytes:
            problems.add(f"merged-binary.bin ({len(merged)} bytes) is larger than the flash")

    # ---- recorded hashes
    sums_path = need("SHA256SUMS")
    if sums_path:
        print("\n=== recorded hashes (SHA256SUMS) ===")
        checked = bad = 0
        for line in sums_path.read_text(encoding="utf-8").splitlines():
            digest, _, name = line.partition("  ")
            if not name:
                continue
            checked += 1
            path = root / name
            if not path.is_file():
                bad += 1
                problems.add(f"SHA256SUMS lists {name}, which is missing")
            elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                bad += 1
                problems.add(f"{name} does not match its recorded SHA-256 (changed since the build)")
        print(f"  {checked - bad}/{checked} files match")

    return finish(problems)


# ----------------------------------------------------------------------------- sdkconfig delta


def read_sdkconfig(path):
    """{CONFIG_X: value} with '# CONFIG_X is not set' as 'n'; the deprecated-alias tail is skipped."""
    values = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip()
        if line.startswith("# Deprecated options for backward compatibility"):
            break
        if line.startswith("CONFIG_") and "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[2:-len(" is not set")]] = "n"
    return values


def config_delta(old_path, new_path):
    """Print the sdkconfig lines that turn old into new, ready for --sdkconfig-append."""
    old, new = read_sdkconfig(old_path), read_sdkconfig(new_path)
    for key, value in new.items():
        if old.get(key) != value:
            print(f"{key}={value}")
    for key, value in old.items():
        if key not in new:
            print(f"# {key} (was {value}) no longer exists in the configuration: a dependency is not met any more")
    return 0


def finish(problems):
    print("\n=== result ===")
    if problems.items:
        print(f"  FAILED - {len(problems.items)} problem(s):")
        for item in problems.items:
            print(f"    - {item}")
        return 1
    print("  OK - all expected files are present, fit their regions and are internally consistent")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    flash_files = sub.add_parser("flash-files", help="list offset<TAB>file from a flasher_args.json")
    flash_files.add_argument("flasher_args")
    inspect_parser = sub.add_parser("inspect", help="report on and verify an artifact directory")
    inspect_parser.add_argument("directory")
    delta = sub.add_parser("config-delta", help="sdkconfig lines that turn OLD into NEW")
    delta.add_argument("old")
    delta.add_argument("new")
    args = parser.parse_args()

    if args.command == "flash-files":
        try:
            _, files = load_flasher_args(args.flasher_args)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(f"inspect_build.py: {error}", file=sys.stderr)
            return 1
        for offset, name in files:
            print(f"0x{offset:x}\t{name}")
        return 0
    if args.command == "config-delta":
        try:
            return config_delta(args.old, args.new)
        except OSError as error:
            print(f"inspect_build.py: {error}", file=sys.stderr)
            return 1
    return inspect(args.directory)


if __name__ == "__main__":
    sys.exit(main())
