#!/usr/bin/env python3
"""espflash.py — read-only parsers for what an ESP32 keeps in its SPI flash.

Library used by analyze_flash_image.py (scripts/30) and compare_images.py (scripts/32).
Standard library only. Nothing here prints, writes files or executes anything from the
image: every function takes bytes and returns plain data objects.

What is understood (formats are those of ESP-IDF; struct names in brackets):
  - image header + segment walk + XOR checksum + appended SHA-256   [esp_image_header_t]
  - application descriptor                                          [esp_app_desc_t]
  - bootloader descriptor (ESP-IDF >= 5.1)                          [esp_bootloader_desc_t]
  - partition table incl. its MD5 record                            [esp_partition_info_t]
  - otadata and the bootloader's slot selection                     [esp_ota_select_entry_t]
  - NVS pages/entries: integers, strings, blobs (v1 single-entry and v2 index+chunks),
    all CRCs checked; erased entries are counted, never decoded     [nvs_flash page format]
  - strings a xiaozhi-esp32 application carries about its board, and URLs
  - xiaozhi "assets" partition and ESP-SR "srmodels" header, plus a few common magics

Known limits: NVS encryption and flash encryption are not handled (such data shows up as
CRC failures / missing magic); the SPIFFS/LittleFS/FAT contents are not walked, only recognised.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import struct
import zlib
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

SECTOR = 0x1000

# ----------------------------------------------------------------------------- helpers


def cstr(raw: bytes) -> str:
    """Bytes up to the first NUL, decoded leniently."""
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def safe(text: str, limit: int = 0) -> str:
    """Make an untrusted string harmless to print: escape control characters."""
    out = []
    for ch in text:
        o = ord(ch)
        if o < 0x20 or o == 0x7F or 0x80 <= o <= 0x9F or o == 0xFFFD:
            out.append("\\x%02x" % o if o < 0x100 else "?")
        else:
            out.append(ch)
    s = "".join(out)
    if limit and len(s) > limit:
        s = s[:limit] + "...(+%d chars)" % (len(s) - limit)
    return s


def is_blank(buf: bytes) -> bool:
    return buf.count(0xFF) == len(buf)


def xor_fold(data: bytes) -> int:
    """XOR of all bytes, done on big integers so megabytes take milliseconds."""
    n = len(data)
    if n == 0:
        return 0
    x = int.from_bytes(data, "little")
    while n > 1:
        half = (n + 1) // 2
        x = (x >> (8 * half)) ^ (x & ((1 << (8 * half)) - 1))
        n = half
    return x & 0xFF


def esp_crc32(data: bytes) -> int:
    """esp_rom_crc32_le(UINT32_MAX, data, len) as used by otadata and NVS."""
    return zlib.crc32(data, 0xFFFFFFFF) & 0xFFFFFFFF


def fmt_size(n: int) -> str:
    if n >= 1 << 20:
        return "%.2f MB" % (n / (1 << 20))
    if n >= 1 << 10:
        return "%.1f KB" % (n / (1 << 10))
    return "%d B" % n


# ----------------------------------------------------------------------------- image header

ESP_IMAGE_MAGIC = 0xE9
ESP_IMAGE_MAX_SEGMENTS = 16
CHIP_IDS = {
    0x0000: "ESP32", 0x0002: "ESP32-S2", 0x0005: "ESP32-C3", 0x0009: "ESP32-S3",
    0x000C: "ESP32-C2", 0x000D: "ESP32-C6", 0x0010: "ESP32-H2", 0x0012: "ESP32-P4",
    0x0014: "ESP32-C61", 0x0017: "ESP32-C5", 0x0019: "ESP32-H21", 0x001C: "ESP32-H4",
    0x0020: "ESP32-S31",
}
SPI_MODES = {0: "QIO", 1: "QOUT", 2: "DIO", 3: "DOUT", 4: "FAST_READ", 5: "SLOW_READ"}
FLASH_SIZES = {0: 1, 1: 2, 2: 4, 3: 8, 4: 16, 5: 32, 6: 64, 7: 128}        # MB
_FREQ_DEFAULT = {0x0: "40 MHz", 0x1: "26 MHz", 0x2: "20 MHz", 0xF: "80 MHz"}
_FREQ_BY_CHIP = {
    0x000C: {0xF: "60 MHz", 0x0: "30 MHz", 0x1: "20 MHz", 0x2: "15 MHz"},
    0x000D: {0x0: "80/40 MHz", 0x2: "20 MHz"},
    0x0010: {0xF: "48 MHz", 0x0: "24 MHz", 0x1: "16 MHz", 0x2: "12 MHz"},
}
# Where the bootloader lives: 0x0 on S3/C3/C2/C6/H2, 0x1000 on ESP32/S2, 0x2000 on P4/C5.
BOOTLOADER_OFFSETS = (0x0, 0x1000, 0x2000)


@dataclass
class ImageHeader:
    magic: int
    segment_count: int
    spi_mode: int
    spi_speed: int
    spi_size: int
    entry: int
    wp_pin: int
    chip_id: int
    min_chip_rev: int
    min_chip_rev_full: int
    max_chip_rev_full: int
    hash_appended: int

    @property
    def chip_name(self) -> str:
        return CHIP_IDS.get(self.chip_id, "unknown")

    @property
    def spi_mode_name(self) -> str:
        return SPI_MODES.get(self.spi_mode, "unknown")

    @property
    def spi_speed_name(self) -> str:
        return _FREQ_BY_CHIP.get(self.chip_id, _FREQ_DEFAULT).get(self.spi_speed, "unknown")

    @property
    def flash_size_mb(self) -> Optional[int]:
        return FLASH_SIZES.get(self.spi_size)


def parse_image_header(buf: bytes, off: int) -> Optional[ImageHeader]:
    if off < 0 or off + 24 > len(buf):
        return None
    h = buf[off:off + 24]
    return ImageHeader(
        magic=h[0], segment_count=h[1], spi_mode=h[2], spi_speed=h[3] & 0x0F, spi_size=h[3] >> 4,
        entry=struct.unpack_from("<I", h, 4)[0], wp_pin=h[8],
        chip_id=struct.unpack_from("<H", h, 12)[0], min_chip_rev=h[14],
        min_chip_rev_full=struct.unpack_from("<H", h, 15)[0],
        max_chip_rev_full=struct.unpack_from("<H", h, 17)[0],
        hash_appended=h[23],
    )


def _region_s3(addr: int) -> str:
    if 0x3C000000 <= addr < 0x3E000000:
        return "DROM (flash-mapped data)"
    if 0x42000000 <= addr < 0x44000000:
        return "IROM (flash-mapped code)"
    if 0x3FC88000 <= addr < 0x3FD00000:
        return "DRAM"
    if 0x40370000 <= addr < 0x403E0000:
        return "IRAM"
    if 0x50000000 <= addr < 0x50002000 or 0x600FE000 <= addr < 0x60100000:
        return "RTC"
    return ""


@dataclass
class Segment:
    index: int
    file_off: int        # absolute offset of the segment *data* in the file
    load_addr: int
    size: int
    region: str = ""


@dataclass
class ImageInfo:
    offset: int
    header: Optional[ImageHeader] = None
    segments: List[Segment] = field(default_factory=list)
    error: Optional[str] = None          # structural reason the walk stopped
    truncated: bool = False              # walk stopped because the available bytes ran out
    checksum_stored: Optional[int] = None
    checksum_calc: Optional[int] = None
    hash_stored: Optional[bytes] = None
    hash_calc: Optional[bytes] = None
    data_len: Optional[int] = None       # header .. checksum byte (multiple of 16)
    total_len: Optional[int] = None      # data_len + 32 if a SHA-256 is appended

    @property
    def checksum_ok(self) -> Optional[bool]:
        if self.checksum_stored is None:
            return None
        return self.checksum_stored == self.checksum_calc

    @property
    def hash_ok(self) -> Optional[bool]:
        if self.hash_stored is None:
            return None
        return self.hash_stored == self.hash_calc

    @property
    def valid(self) -> bool:
        return (self.error is None and self.checksum_ok is True
                and (self.hash_stored is None or self.hash_ok is True))


def parse_image(buf: bytes, base: int, limit: Optional[int] = None) -> ImageInfo:
    """Walk an ESP image the way the bootloader does (esp_image_verify).

    `limit` is the absolute offset the image must not cross (end of its partition);
    the file end always limits too.
    """
    hard = len(buf) if limit is None else min(len(buf), limit)
    by_file = limit is None or len(buf) <= limit
    what = "end of file" if by_file else "end of the partition"
    info = ImageInfo(offset=base)
    hdr = parse_image_header(buf, base) if base + 24 <= hard else None
    if hdr is None:
        info.error = "fewer than 24 bytes available for the image header"
        info.truncated = True
        return info
    info.header = hdr
    if hdr.magic != ESP_IMAGE_MAGIC:
        info.error = "no ESP image here: first byte is 0x%02x, expected 0xE9" % hdr.magic
        return info
    if not 1 <= hdr.segment_count <= ESP_IMAGE_MAX_SEGMENTS:
        info.error = "implausible segment count %d" % hdr.segment_count
        return info
    pos = base + 24
    chk = 0xEF
    for i in range(hdr.segment_count):
        if pos + 8 > hard:
            info.error = "segment %d header lies beyond the %s" % (i, what)
            info.truncated = by_file
            return info
        addr, size = struct.unpack_from("<II", buf, pos)
        data_off = pos + 8
        if size > 0x4000000:
            info.error = "segment %d claims %d bytes - not an image, or corrupt" % (i, size)
            return info
        if data_off + size > hard:
            info.error = ("segment %d (0x%x bytes at 0x%x) runs past the %s at 0x%x"
                          % (i, size, data_off, what, hard))
            info.truncated = by_file
            return info
        chk ^= xor_fold(buf[data_off:data_off + size])
        region = _region_s3(addr) if hdr.chip_id == 0x0009 else ""
        info.segments.append(Segment(i, data_off, addr, size, region))
        pos = data_off + size
    length = (pos - base + 1 + 15) & ~15                 # + checksum byte, padded to 16
    if base + length > hard:
        info.error = "checksum byte lies beyond the %s" % what
        info.truncated = by_file
        return info
    info.checksum_stored = buf[base + length - 1]
    info.checksum_calc = chk
    info.data_len = length
    info.total_len = length
    if hdr.hash_appended == 1:
        if base + length + 32 > hard:
            info.error = "appended SHA-256 lies beyond the %s" % what
            info.truncated = by_file
            return info
        info.hash_stored = bytes(buf[base + length:base + length + 32])
        info.hash_calc = hashlib.sha256(buf[base:base + length]).digest()
        info.total_len = length + 32
    return info


# ----------------------------------------------------------------------------- descriptors

APP_DESC_MAGIC = 0xABCD5432
BOOTLOADER_DESC_MAGIC = 0x50
DESC_OFFSET = 0x20        # sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t)


@dataclass
class AppDesc:
    secure_version: int
    version: str
    project_name: str
    time: str
    date: str
    idf_ver: str
    elf_sha256: bytes


def parse_app_desc(buf: bytes, image_off: int) -> Optional[AppDesc]:
    off = image_off + DESC_OFFSET
    if off + 256 > len(buf) or struct.unpack_from("<I", buf, off)[0] != APP_DESC_MAGIC:
        return None
    d = buf[off:off + 256]
    return AppDesc(
        secure_version=struct.unpack_from("<I", d, 4)[0],
        version=cstr(d[16:48]), project_name=cstr(d[48:80]),
        time=cstr(d[80:96]), date=cstr(d[96:112]), idf_ver=cstr(d[112:144]),
        elf_sha256=bytes(d[144:176]),
    )


@dataclass
class BootloaderDesc:
    secure_version: int
    version: int
    idf_ver: str
    date_time: str


def _plain_ascii(raw: bytes) -> bool:
    text = raw.split(b"\0", 1)[0]
    return len(text) > 0 and all(0x20 <= c < 0x7F for c in text) and not raw[len(text):].strip(b"\0")


def parse_bootloader_desc(buf: bytes, image_off: int) -> Optional[BootloaderDesc]:
    off = image_off + DESC_OFFSET
    if off + 80 > len(buf) or buf[off] != BOOTLOADER_DESC_MAGIC:
        return None
    d = buf[off:off + 80]
    # Older bootloaders have no descriptor; whatever sits here must really look like one.
    if not _plain_ascii(d[8:40]) or not _plain_ascii(d[40:64]):
        return None
    return BootloaderDesc(secure_version=d[3], version=struct.unpack_from("<I", d, 4)[0],
                          idf_ver=cstr(d[8:40]), date_time=cstr(d[40:64]))


# ----------------------------------------------------------------------------- partition table

PT_OFFSET_DEFAULT = 0x8000
PT_MAX_LEN = 0xC00
PT_MAGIC = b"\xAA\x50"
PT_MD5_MAGIC = b"\xEB\xEB"
TYPE_NAMES = {0x00: "app", 0x01: "data", 0x02: "bootloader", 0x03: "partition_table"}
APP_SUBTYPES = {0x00: "factory", 0x20: "test", 0x30: "tee_0", 0x31: "tee_1"}
DATA_SUBTYPES = {
    0x00: "ota", 0x01: "phy", 0x02: "nvs", 0x03: "coredump", 0x04: "nvs_keys", 0x05: "efuse",
    0x06: "undefined", 0x80: "esphttpd", 0x81: "fat", 0x82: "spiffs", 0x83: "littlefs",
    0x90: "tee_ota",
}
FLAG_NAMES = {0: "encrypted", 1: "readonly"}


@dataclass
class Partition:
    index: int
    name: str
    type: int
    subtype: int
    offset: int
    size: int
    flags: int

    @property
    def end(self) -> int:
        return self.offset + self.size

    @property
    def type_name(self) -> str:
        return TYPE_NAMES.get(self.type, "0x%02x" % self.type)

    @property
    def subtype_name(self) -> str:
        if self.type == 0x00:
            if 0x10 <= self.subtype <= 0x1F:
                return "ota_%d" % (self.subtype - 0x10)
            return APP_SUBTYPES.get(self.subtype, "0x%02x" % self.subtype)
        if self.type == 0x01:
            return DATA_SUBTYPES.get(self.subtype, "0x%02x" % self.subtype)
        if self.type in (0x02, 0x03):
            return {0: "primary", 1: "ota", 2: "recovery"}.get(self.subtype, "0x%02x" % self.subtype)
        return "0x%02x" % self.subtype

    @property
    def flag_names(self) -> str:
        names = [n for bit, n in FLAG_NAMES.items() if self.flags & (1 << bit)]
        rest = self.flags & ~0x3
        if rest:
            names.append("0x%x" % rest)
        return ",".join(names)

    @property
    def is_app(self) -> bool:
        return self.type == 0x00

    @property
    def ota_index(self) -> Optional[int]:
        if self.type == 0x00 and 0x10 <= self.subtype <= 0x1F:
            return self.subtype - 0x10
        return None


@dataclass
class PartitionTable:
    offset: int
    entries: List[Partition] = field(default_factory=list)
    md5_present: bool = False
    md5_stored: Optional[bytes] = None
    md5_calc: Optional[bytes] = None
    terminated: bool = False             # an all-0xFF end marker follows the entries
    errors: List[str] = field(default_factory=list)

    @property
    def md5_ok(self) -> Optional[bool]:
        if not self.md5_present:
            return None
        return self.md5_stored == self.md5_calc

    def find(self, name: str) -> Optional[Partition]:
        for p in self.entries:
            if p.name == name:
                return p
        return None

    def problems(self, flash_bytes: Optional[int]) -> List[str]:
        out = list(self.errors)
        ordered = sorted(self.entries, key=lambda p: p.offset)
        for a, b in zip(ordered, ordered[1:]):
            if a.end > b.offset:
                out.append("partitions %s and %s overlap" % (a.name, b.name))
        seen = set()
        for p in self.entries:
            if p.name in seen:
                out.append("partition name %s is used twice" % p.name)
            seen.add(p.name)
            if p.offset < self.offset + SECTOR:
                out.append("partition %s starts inside/before the partition table" % p.name)
            if p.is_app and p.offset % 0x10000:
                out.append("app partition %s is not aligned to 0x10000" % p.name)
            if flash_bytes and p.end > flash_bytes:
                out.append("partition %s ends at 0x%x, beyond the %d MB flash"
                           % (p.name, p.end, flash_bytes >> 20))
        return out


def parse_partition_table(buf: bytes, off: int = PT_OFFSET_DEFAULT) -> Optional[PartitionTable]:
    """Partition table at `off`, or None if there is no partition magic there."""
    if off + 32 > len(buf) or buf[off:off + 2] != PT_MAGIC:
        return None
    table = PartitionTable(offset=off)
    md5 = hashlib.md5(usedforsecurity=False)
    pos = off
    end = min(len(buf), off + PT_MAX_LEN)
    while pos + 32 <= end:
        rec = buf[pos:pos + 32]
        if rec == b"\xFF" * 32:
            table.terminated = True
            break
        if rec[:2] == PT_MD5_MAGIC:
            table.md5_present = True
            table.md5_stored = bytes(rec[16:32])
            table.md5_calc = md5.digest()
            pos += 32
            continue
        if rec[:2] != PT_MAGIC:
            table.errors.append("record at 0x%x has unknown magic %s" % (pos, rec[:2].hex()))
            break
        md5.update(rec)
        ptype, subtype, p_off, p_size = struct.unpack_from("<BBII", rec, 2)
        flags = struct.unpack_from("<I", rec, 28)[0]
        table.entries.append(Partition(len(table.entries), cstr(rec[12:28]), ptype, subtype,
                                       p_off, p_size, flags))
        pos += 32
    if not table.terminated and not table.errors:
        table.errors.append("no end-of-table marker within 0x%x bytes" % PT_MAX_LEN)
    return table


def find_partition_table(buf: bytes) -> Optional[PartitionTable]:
    """Default offset first; otherwise look at every 4 KiB boundary in the first MiB."""
    table = parse_partition_table(buf, PT_OFFSET_DEFAULT)
    if table is not None:
        return table
    for off in range(SECTOR, min(len(buf), 0x100000), SECTOR):
        if buf[off:off + 2] == PT_MAGIC:
            table = parse_partition_table(buf, off)
            if table is not None and table.entries and (table.md5_ok or len(table.entries) >= 2):
                return table
    return None


def _csv_number(text: str) -> Optional[int]:
    text = text.strip()
    if not text:
        return None
    mult = 1
    if text[-1] in "kK":
        mult, text = 1024, text[:-1]
    elif text[-1] in "mM":
        mult, text = 1024 * 1024, text[:-1]
    return int(text, 0) * mult


def parse_partition_csv(path: str) -> List[Tuple[str, str, str, int, int]]:
    """(name, type, subtype, offset, size) per row, offsets filled in like gen_esp32part.py."""
    rows = []
    last_end = PT_OFFSET_DEFAULT + SECTOR
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            cols = [c.strip() for c in line.split(",")]
            if len(cols) < 5:
                continue
            name, ptype, subtype = cols[0], cols[1], cols[2]
            offset, size = _csv_number(cols[3]), _csv_number(cols[4])
            if size is None:
                continue
            if offset is None:
                align = 0x10000 if ptype == "app" else 0x1000
                offset = (last_end + align - 1) // align * align
            rows.append((name, ptype, subtype, offset, size))
            last_end = offset + size
    return rows


def match_partition_csvs(table: PartitionTable, src_root: str) -> Tuple[List[str], int]:
    """Names of partitions/**/*.csv in the source tree that describe exactly this table."""
    hits = []
    count = 0
    base = os.path.join(src_root, "partitions")
    mine = [(p.name, p.type_name, p.subtype_name, p.offset, p.size) for p in table.entries]
    for dirpath, dirs, files in os.walk(base):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith(".csv"):
                continue
            count += 1
            try:
                rows = parse_partition_csv(os.path.join(dirpath, fn))
            except (OSError, ValueError):
                continue
            if rows == mine:
                hits.append(os.path.relpath(os.path.join(dirpath, fn), src_root))
    return hits, count


# ----------------------------------------------------------------------------- otadata

OTA_STATES = {0: "NEW", 1: "PENDING_VERIFY", 2: "VALID", 3: "INVALID", 4: "ABORTED",
              0xFFFFFFFF: "UNDEFINED"}
FACTORY_INDEX = -1


@dataclass
class OtaEntry:
    copy: int
    seq: int
    state: int
    crc_stored: int
    crc_calc: int
    blank: bool            # the 32-byte record is all 0xFF

    @property
    def crc_ok(self) -> bool:
        return self.crc_stored == self.crc_calc

    @property
    def state_name(self) -> str:
        return OTA_STATES.get(self.state, "0x%08x" % self.state)

    @property
    def invalid(self) -> bool:          # bootloader_common_ota_select_invalid()
        return self.seq == 0xFFFFFFFF or self.state in (3, 4)

    @property
    def valid(self) -> bool:            # bootloader_common_ota_select_valid()
        return not self.invalid and self.crc_ok


def parse_otadata(part: bytes) -> List[Optional[OtaEntry]]:
    """The two esp_ota_select_entry_t copies (one per 4 KiB sector). None = not in the file."""
    out: List[Optional[OtaEntry]] = []
    for i in range(2):
        rec = part[i * SECTOR:i * SECTOR + 32]
        if len(rec) < 32:
            out.append(None)
            continue
        seq, _label, state, crc = struct.unpack("<I20sII", rec)
        out.append(OtaEntry(i, seq, state, crc, esp_crc32(rec[:4]), is_blank(rec)))
    return out


@dataclass
class BootChoice:
    index: int                  # OTA slot number, or FACTORY_INDEX
    active_copy: Optional[int]  # which otadata copy decided, if any
    reason: str
    order: List[int] = field(default_factory=list)   # slots the bootloader tries, in order


def select_boot(entries: List[Optional[OtaEntry]], ota_count: int, has_factory: bool) -> BootChoice:
    """bootloader_utility_get_selected_boot_partition() + the fallback order of
    bootloader_utility_load_boot_image()."""
    e = [x for x in entries if x is not None]
    if len(e) < 2 and ota_count:
        # otadata (partly) missing from the file: decide as if those copies were blank
        e = e + [OtaEntry(len(e) + k, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0, True) for k in range(2 - len(e))]
    if not entries or ota_count == 0 or all(x.invalid for x in e):
        if has_factory:
            choice = BootChoice(FACTORY_INDEX, None, "otadata is blank/invalid -> factory app")
        else:
            choice = BootChoice(0, None, "otadata is blank and there is no factory app -> first OTA slot")
    else:
        valid = [x for x in e if x.valid]
        if not valid:
            choice = BootChoice(FACTORY_INDEX, None,
                                "otadata has no entry with a good CRC -> factory app (or next valid slot)")
        else:
            best = valid[0]
            for x in valid[1:]:
                if x.seq > best.seq:
                    best = x
            slot = (best.seq - 1) % ota_count
            choice = BootChoice(slot, best.copy,
                                "otadata copy %d has the highest valid sequence %d -> (%d - 1) mod %d slots = %d"
                                % (best.copy, best.seq, best.seq, ota_count, slot))
    order = list(range(choice.index, FACTORY_INDEX - 1, -1))       # downwards to factory
    order += list(range(choice.index + 1, ota_count))             # then upwards
    choice.order = order
    return choice


# ----------------------------------------------------------------------------- NVS

NVS_PAGE = 0x1000
NVS_ENTRY = 32
NVS_ENTRIES = 126
NVS_PAGE_STATES = {0xFFFFFFFF: "EMPTY", 0xFFFFFFFE: "ACTIVE", 0xFFFFFFFC: "FULL",
                   0xFFFFFFF8: "FREEING", 0xFFFFFFF0: "CORRUPT", 0x00000000: "INVALID"}
NVS_TYPES = {0x01: "u8", 0x11: "i8", 0x02: "u16", 0x12: "i16", 0x04: "u32", 0x14: "i32",
             0x08: "u64", 0x18: "i64", 0x21: "string", 0x41: "blob", 0x42: "blob_data",
             0x48: "blob_index"}
_NVS_INT_FMT = {0x01: "<B", 0x11: "<b", 0x02: "<H", 0x12: "<h", 0x04: "<I", 0x14: "<i",
                0x08: "<Q", 0x18: "<q"}
_ST_EMPTY, _ST_WRITTEN, _ST_ERASED = 3, 2, 0


@dataclass
class NvsPage:
    index: int
    state: int
    seq: int
    version: int
    crc_ok: bool
    blank: bool
    written: int = 0
    erased: int = 0
    empty: int = 0
    bad: int = 0             # written entries whose CRC fails / that cannot be parsed

    @property
    def state_name(self) -> str:
        return NVS_PAGE_STATES.get(self.state, "0x%08x" % self.state)


@dataclass
class NvsItem:
    """One live key. `value` is int for integer types, str for strings, bytes for blobs."""
    namespace: str
    ns_index: int
    key: str
    type_name: str
    value: object
    size: int                # bytes of payload (strings: without the NUL)
    page: int
    entry: int
    complete: bool = True    # False: data CRC failed or blob chunks missing
    note: str = ""


@dataclass
class NvsDump:
    pages: List[NvsPage] = field(default_factory=list)
    namespaces: Dict[int, str] = field(default_factory=dict)
    items: List[NvsItem] = field(default_factory=list)
    erased_keys: Dict[Tuple[str, str], int] = field(default_factory=dict)  # (namespace, key) -> count
    problems: List[str] = field(default_factory=list)
    truncated: bool = False

    @property
    def blank(self) -> bool:
        return bool(self.pages) and all(p.blank for p in self.pages)

    def get(self, namespace: str, key: str) -> Optional[NvsItem]:
        for it in self.items:
            if it.namespace == namespace and it.key == key:
                return it
        return None


def _nvs_entry_state(bitmap: bytes, i: int) -> int:
    return (bitmap[i // 4] >> ((i % 4) * 2)) & 0x3


def parse_nvs(part: bytes) -> NvsDump:
    """Decode an NVS partition image. Later pages (higher sequence number) win."""
    dump = NvsDump()
    if len(part) % NVS_PAGE:
        dump.truncated = True
    raw_pages = []
    for pi in range(len(part) // NVS_PAGE):
        pg = part[pi * NVS_PAGE:(pi + 1) * NVS_PAGE]
        state, seq = struct.unpack_from("<II", pg, 0)
        version = pg[8]
        crc_ok = esp_crc32(pg[4:28]) == struct.unpack_from("<I", pg, 28)[0]
        page = NvsPage(pi, state, seq, version, crc_ok, is_blank(pg))
        dump.pages.append(page)
        if page.blank or state == 0xFFFFFFFF:
            continue
        if state not in (0xFFFFFFFE, 0xFFFFFFFC, 0xFFFFFFF8):
            dump.problems.append("page %d is in state %s - not read" % (pi, page.state_name))
            continue
        if not crc_ok:
            dump.problems.append("page %d: header CRC mismatch (NVS would discard this page)" % pi)
            continue
        raw_pages.append((seq, pi, pg, page))

    raw_pages.sort(key=lambda t: (t[0], t[1]))
    # First pass: collect every written entry in write order.
    records = []          # (page, entry, ns, type, chunk_index, key, data8, payload, payload_ok)
    erased = []           # (ns, key) of erased-but-still-readable headers
    for _seq, pi, pg, page in raw_pages:
        bitmap = pg[32:64]
        i = 0
        while i < NVS_ENTRIES:
            st = _nvs_entry_state(bitmap, i)
            ent = pg[64 + i * NVS_ENTRY:64 + (i + 1) * NVS_ENTRY]
            if st == _ST_EMPTY:
                page.empty += 1
                i += 1
                continue
            ns, etype, span, chunk = ent[0], ent[1], ent[2], ent[3]
            crc_ok = esp_crc32(ent[0:4] + ent[8:32]) == struct.unpack_from("<I", ent, 4)[0]
            sane = crc_ok and etype in NVS_TYPES and 1 <= span <= NVS_ENTRIES - i
            if st == _ST_ERASED:
                if sane:
                    erased.append((ns, cstr(ent[8:24])))
                    page.erased += span
                    i += span
                else:
                    page.erased += 1
                    i += 1
                continue
            if st != _ST_WRITTEN or not sane:
                page.bad += 1
                i += 1
                continue
            page.written += span
            key = cstr(ent[8:24])
            data8 = ent[24:32]
            payload = None
            payload_ok = True
            if etype in (0x21, 0x41, 0x42):
                size, _rsv, dcrc = struct.unpack("<HHI", data8)
                start = 64 + (i + 1) * NVS_ENTRY
                payload = bytes(pg[start:start + size])
                payload_ok = (size <= (span - 1) * NVS_ENTRY and len(payload) == size
                              and esp_crc32(payload) == dcrc)
            records.append((pi, i, ns, etype, chunk, key, data8, payload, payload_ok))
            i += span

    # Namespace table: entries with ns == 0, type u8; the value is the namespace index.
    for pi, i, ns, etype, chunk, key, data8, payload, ok in records:
        if ns == 0 and etype == 0x01:
            dump.namespaces[data8[0]] = key

    def ns_name(idx: int) -> str:
        return dump.namespaces.get(idx, "ns#%d" % idx)

    for ns, key in erased:
        if ns == 0:
            continue
        k = (ns_name(ns), key)
        dump.erased_keys[k] = dump.erased_keys.get(k, 0) + 1

    # Second pass: resolve live values; a later record for the same key replaces an earlier one.
    live: Dict[Tuple[int, str], NvsItem] = {}
    blob_idx: Dict[Tuple[int, str], Tuple[int, int, int, int, int]] = {}   # size, count, start, page, entry
    chunks: Dict[Tuple[int, str], Dict[int, Tuple[bytes, bool]]] = {}
    for pi, i, ns, etype, chunk, key, data8, payload, ok in records:
        if ns == 0:
            continue
        ident = (ns, key)
        if etype in _NVS_INT_FMT:
            value = struct.unpack_from(_NVS_INT_FMT[etype], data8, 0)[0]
            width = struct.calcsize(_NVS_INT_FMT[etype])
            live[ident] = NvsItem(ns_name(ns), ns, key, NVS_TYPES[etype], value, width, pi, i)
        elif etype == 0x21:
            text = payload[:-1] if payload.endswith(b"\0") else payload
            live[ident] = NvsItem(ns_name(ns), ns, key, "string", text.decode("utf-8", "replace"),
                                  len(text), pi, i, complete=ok,
                                  note="" if ok else "data CRC mismatch")
        elif etype == 0x41:
            live[ident] = NvsItem(ns_name(ns), ns, key, "blob", payload, len(payload), pi, i,
                                  complete=ok, note="" if ok else "data CRC mismatch")
        elif etype == 0x48:
            size, count, start = struct.unpack_from("<IBB", data8, 0)
            blob_idx[ident] = (size, count, start, pi, i)
        elif etype == 0x42:
            chunks.setdefault(ident, {})[chunk] = (payload, ok)
    for ident, (size, count, start, pi, i) in blob_idx.items():
        ns, key = ident
        have = chunks.get(ident, {})
        parts = []
        complete = True
        for c in range(start, start + count):
            if c not in have:
                complete = False
                continue
            parts.append(have[c][0])
            complete = complete and have[c][1]
        data = b"".join(parts)
        note = ""
        if not complete or len(data) != size:
            complete = False
            note = "blob incomplete: have %d of %d bytes in %d/%d chunks" % (len(data), size, len(parts), count)
        live[ident] = NvsItem(ns_name(ns), ns, key, "blob", data, len(data), pi, i, complete=complete, note=note)
    for ident, have in chunks.items():
        if ident not in blob_idx:
            dump.problems.append("blob data chunks for %s/%s without an index entry" % (ns_name(ident[0]), ident[1]))
    dump.items = sorted(live.values(), key=lambda it: (it.ns_index, it.page, it.entry))
    for page in dump.pages:
        if page.bad:
            dump.problems.append("page %d: %d written entries fail their CRC (corruption, or NVS encryption)"
                                 % (page.index, page.bad))
    return dump


# ----------------------------------------------------------------------------- application strings

_IDENT = rb"[a-z0-9][a-z0-9._-]{1,62}"
_RE_MCP_NAME = re.compile(rb'"serverInfo":\{"name":"(' + _IDENT + rb')","version":"')
_RE_JSON_TYPE = re.compile(rb'\{"type":"(' + _IDENT + rb')",')
_RE_JSON_NAME = re.compile(rb'"name":"(' + _IDENT + rb')",\x00')
_RE_SRC_PATH = re.compile(rb"main/boards/((?:[A-Za-z0-9._-]+/){1,3})([A-Za-z0-9._-]+\.(?:cc|cpp|c|hpp|h))\x00")
_RE_TOKEN = re.compile(rb"(?<![A-Za-z0-9._/-])(" + _IDENT + rb")(/?)\x00")
_RE_URL = re.compile(rb"(?:https?|wss?|mqtts?)://[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]{3,300}")


@dataclass
class AppStrings:
    mcp_names: List[str] = field(default_factory=list)      # BOARD_NAME via MCP serverInfo (v2.x)
    json_types: List[str] = field(default_factory=list)     # BOARD_TYPE via {"type":"...", (v1.x, 4G boards)
    json_names: List[str] = field(default_factory=list)     # BOARD_NAME via "name":"...", (v1.x, 4G boards)
    board_dirs: Dict[str, List[str]] = field(default_factory=dict)   # main/boards/<dir> -> source files seen
    tokens: Dict[str, str] = field(default_factory=dict)    # identifier -> "plain" / "slash" / "both"
    urls: List[str] = field(default_factory=list)


def scan_app_strings(app: bytes) -> AppStrings:
    """Pull the identifying string constants out of an application image."""
    out = AppStrings()

    def uniq(regex) -> List[str]:
        seen: List[str] = []
        for m in regex.finditer(app):
            v = m.group(1).decode("ascii")
            if v not in seen:
                seen.append(v)
        return seen

    out.mcp_names = uniq(_RE_MCP_NAME)
    out.json_types = uniq(_RE_JSON_TYPE)
    out.json_names = uniq(_RE_JSON_NAME)
    for m in _RE_SRC_PATH.finditer(app):
        d = m.group(1).decode("ascii").rstrip("/")
        f = m.group(2).decode("ascii")
        if d == "common" or d.startswith("common/"):
            continue
        files = out.board_dirs.setdefault(d, [])
        if f not in files:
            files.append(f)
    for m in _RE_TOKEN.finditer(app):
        tok = m.group(1).decode("ascii")
        kind = "slash" if m.group(2) else "plain"
        prev = out.tokens.get(tok)
        out.tokens[tok] = kind if prev in (None, kind) else "both"
    for m in _RE_URL.finditer(app):
        u = m.group(0).decode("ascii")
        if u not in out.urls:
            out.urls.append(u)
    return out


# ----------------------------------------------------------------------------- source tree

@dataclass
class BoardCatalog:
    root: str
    version: str = ""                                               # PROJECT_VER
    dirs: Dict[str, dict] = field(default_factory=dict)             # "vendor/board" -> config
    by_type: Dict[str, List[str]] = field(default_factory=dict)     # type -> [dir]
    by_name: Dict[str, List[str]] = field(default_factory=dict)     # build name -> [dir]
    ota_url_default: str = ""

    def dirs_for_basename(self, base: str) -> List[str]:
        return [d for d in self.dirs if d.split("/")[-1] == base]


def load_board_catalog(src_root: str) -> Optional[BoardCatalog]:
    """Board types/names from every main/boards/**/config.json of a xiaozhi-esp32 checkout."""
    boards = os.path.join(src_root, "main", "boards")
    if not os.path.isdir(boards):
        return None
    cat = BoardCatalog(root=src_root)
    for dirpath, dirs, files in os.walk(boards):
        dirs.sort()
        if "config.json" not in files:
            continue
        rel = os.path.relpath(dirpath, boards).replace(os.sep, "/")
        if rel == "common" or rel.startswith("common/"):
            continue
        try:
            with open(os.path.join(dirpath, "config.json"), "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(cfg, dict):
            continue
        btype = cfg.get("type") if isinstance(cfg.get("type"), str) else rel.replace("/", "-")
        names = [b.get("name") for b in cfg.get("builds", []) if isinstance(b, dict) and isinstance(b.get("name"), str)]
        cat.dirs[rel] = {"type": btype, "names": names, "target": cfg.get("target", ""),
                         "manufacturer": cfg.get("manufacturer", "")}
        cat.by_type.setdefault(btype, []).append(rel)
        for n in names:
            cat.by_name.setdefault(n, []).append(rel)
    try:
        with open(os.path.join(src_root, "CMakeLists.txt"), "r", encoding="utf-8", errors="replace") as f:
            m = re.search(r'set\(PROJECT_VER\s+"([^"]+)"\)', f.read())
            cat.version = m.group(1) if m else ""
    except OSError:
        pass
    try:
        with open(os.path.join(src_root, "main", "Kconfig.projbuild"), "r", encoding="utf-8", errors="replace") as f:
            m = re.search(r'^config OTA_URL\b.*?^\s*default\s+"([^"]+)"', f.read(), re.S | re.M)
            cat.ota_url_default = m.group(1) if m else ""
    except OSError:
        pass
    return cat


# ----------------------------------------------------------------------------- data partitions

def sniff_assets(part: bytes, part_size: int) -> Optional[dict]:
    """xiaozhi 'assets' image: u32 files, u32 checksum, u32 length, then a 44-byte record per file."""
    if len(part) < 12 + 44:
        return None
    files, chk, length = struct.unpack_from("<III", part, 0)
    if not (1 <= files <= 4096 and 44 * files <= length <= part_size - 12):
        return None
    names = []
    for i in range(files):
        rec = part[12 + 44 * i:12 + 44 * (i + 1)]
        if len(rec) < 44:
            break
        raw = rec[:32].split(b"\0", 1)[0]
        if not raw or any(c < 0x20 or c >= 0x7F for c in raw):
            return None
        names.append(raw.decode("ascii"))
    info = {"files": files, "length": length, "names": names, "checksum_stored": chk,
            "checksum_ok": None, "present": min(len(part), 12 + length)}
    if len(part) >= 12 + length:
        info["checksum_ok"] = (sum(part[12:12 + length]) & 0xFFFF) == chk
    return info


def sniff_srmodels(part: bytes) -> Optional[List[str]]:
    """ESP-SR srmodels.bin: u32 model count, then per model name[32], u32 files, files x (name[32], u32, u32)."""
    if len(part) < 40:
        return None
    count = struct.unpack_from("<I", part, 0)[0]
    if not 1 <= count <= 64:
        return None
    pos = 4
    names = []
    for _ in range(count):
        if pos + 36 > len(part):
            return None
        raw = part[pos:pos + 32].split(b"\0", 1)[0]
        nfiles = struct.unpack_from("<I", part, pos + 32)[0]
        if not raw or any(c < 0x20 or c >= 0x7F for c in raw) or not 1 <= nfiles <= 64:
            return None
        names.append(raw.decode("ascii"))
        pos += 36 + nfiles * 40
    return names


def sniff_magic(part: bytes, part_size: int) -> str:
    """Name a few well-known formats by their first bytes. '' if nothing is recognised."""
    head = part[:16]
    if len(head) >= 16 and head[0] == ESP_IMAGE_MAGIC and 1 <= head[1] <= ESP_IMAGE_MAX_SEGMENTS \
            and struct.unpack_from("<H", head, 12)[0] in CHIP_IDS:
        return "ESP application/bootloader image"
    if len(part) >= 32 and struct.unpack_from("<I", part, 0)[0] in (0xFFFFFFFE, 0xFFFFFFFC) \
            and esp_crc32(part[4:28]) == struct.unpack_from("<I", part, 28)[0]:
        return "NVS page"
    if part[8:16] == b"littlefs":
        return "LittleFS superblock"
    if len(part) >= 512 and part[510:512] == b"\x55\xAA" and (part[54:57] == b"FAT" or part[82:85] == b"FAT"):
        return "FAT boot sector"
    if len(part) >= 256 and part_size >= SECTOR:
        # SPIFFS as ESP-IDF builds it: 256-byte pages, 4 KiB blocks, magic in the block's lookup page
        blocks = part_size // SECTOR
        if struct.unpack_from("<H", part, 252)[0] == ((0x20140529 ^ 256 ^ blocks) & 0xFFFF):
            return "SPIFFS (block magic matches)"
    for sig, name in ((b"PK\x03\x04", "ZIP archive"), (b"\x1f\x8b", "gzip stream"), (b"OggS", "Ogg stream"),
                      (b"RIFF", "RIFF container"), (b"\x89PNG", "PNG image"), (b"\xff\xd8\xff", "JPEG image"),
                      (b"GIF8", "GIF image"), (b"ESP_PHY_INIT", "PHY init data"), (b"PHYINIT", "PHY init data")):
        if part.startswith(sig):
            return name
    return ""
