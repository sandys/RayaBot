#!/usr/bin/env python3
"""selftest_flash_tools.py — the engine of scripts/39-selftest-flash-tools.sh.

    python3 -I -B selftest_flash_tools.py [--source DIR] [--keep]

Builds small synthetic flash images in a temporary directory and runs the real
analysis tools (analyze_flash_image.py, compare_images.py) on them as separate
processes, exactly as scripts/30 and scripts/32 do. Nothing here touches a real
dump, the network or the device.

What it proves
  privacy   NVS secrets planted in the image (WiFi password, an *erased* old password,
            PMK, MQTT/websocket credentials, UUID, token-like values under innocent key
            names, a password inside JSON, URL user info and query strings) never appear
            in the default output - and do appear with --secrets, so the negative result
            is meaningful. --secrets is refused when stdout is not a terminal.
  parsing   bootloader/app checksum + SHA-256, partition table MD5, otadata selection and
            fallback, NVS integers / strings / v1 and multi-page v2 blobs / erased entries,
            board identification for v2-style and v1-style string layouts
  damage    a flipped byte, a broken MD5 and a truncated file are reported, with exit status 3
  compare   identical / differs at the right offset / beyond end of file

The NVS and image writers below are this project's own code, so they cannot prove that
the parsers match ESP-IDF: that is what scripts/33-crosscheck-idf-tools.sh is for (it runs
Espressif's own tools in the build container). This file tests our logic and our redaction.
"""

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import espflash as E  # noqa: E402

FAILS = []
PASSES = 0


def check(cond: bool, what: str):
    global PASSES
    if cond:
        PASSES += 1
        print("  ok    %s" % what)
    else:
        FAILS.append(what)
        print("  FAIL  %s" % what)


def crc(data: bytes) -> int:
    return zlib.crc32(data, 0xFFFFFFFF) & 0xFFFFFFFF


# ----------------------------------------------------------------------------- writers

def make_image(segments, entry=0x40378000, chip_id=0x0009, hash_appended=True) -> bytes:
    hdr = bytes([0xE9, len(segments), 0x02, 0x2F]) + struct.pack("<I", entry) + bytes([0xEE, 0, 0, 0])
    hdr += struct.pack("<HBHH", chip_id, 0, 0, 99) + bytes(4) + bytes([1 if hash_appended else 0])
    body = b""
    chk = 0xEF
    for addr, data in segments:
        body += struct.pack("<II", addr, len(data)) + data
        for b in data:
            chk ^= b
    img = hdr + body
    img += bytes((-(len(img) + 1)) % 16) + bytes([chk])
    if hash_appended:
        img += hashlib.sha256(img).digest()
    return img


def app_desc(version: str, project="xiaozhi", idf="v5.4.1") -> bytes:
    d = struct.pack("<II8x", 0xABCD5432, 0)
    d += version.encode().ljust(32, b"\0") + project.encode().ljust(32, b"\0")
    d += b"12:34:56".ljust(16, b"\0") + b"Jan  2 2025".ljust(16, b"\0") + idf.encode().ljust(32, b"\0")
    d += hashlib.sha256(version.encode()).digest()
    return d.ljust(256, b"\0")


def make_app(version: str, strings: bytes) -> bytes:
    drom = app_desc(version) + b"\0" + strings + b"\0"
    drom += bytes((-len(drom)) % 4)
    irom = bytes(range(256)) * 64
    return make_image([(0x3C0A0020, drom), (0x3FC90000, b"\x11" * 300), (0x42000020, irom)])


def make_bootloader() -> bytes:
    desc = bytes([0x50, 0, 0, 0]) + struct.pack("<I", 1) + b"v5.4.1".ljust(32, b"\0") + b"Jan  2 2025 12:00:00".ljust(24, b"\0") + bytes(16)
    return make_image([(0x3FCE2820, desc + b"\x22" * 64), (0x403C8700, b"\x33" * 1000)], entry=0x403C8904)


def make_table(rows) -> bytes:
    body = b""
    for name, ptype, subtype, off, size in rows:
        body += b"\xAA\x50" + bytes([ptype, subtype]) + struct.pack("<II", off, size) + name.encode().ljust(16, b"\0") + struct.pack("<I", 0)
    body += b"\xEB\xEB" + b"\xFF" * 14 + hashlib.md5(body).digest()
    return body.ljust(0x1000, b"\xFF")


def ota_entry(seq: int, state: int = 0xFFFFFFFF, good_crc: bool = True) -> bytes:
    c = crc(struct.pack("<I", seq))
    return struct.pack("<I20sII", seq, b"\xFF" * 20, state, c if good_crc else c ^ 1)


class NvsWriter:
    """Minimal NVS image writer (our own reading of the format - see the module docstring)."""

    def __init__(self, pages: int):
        self.pages = [bytearray(b"\xFF" * 4096) for _ in range(pages)]
        self.page = 0
        self.slot = 0
        self.ns = {}
        self.used = set()

    def _state(self, page: int, slot: int, st: int):
        b = 32 + slot // 4
        shift = (slot % 4) * 2
        self.pages[page][b] = (self.pages[page][b] & ~(3 << shift) & 0xFF) | (st << shift)

    def _write(self, ns: int, typ: int, key: str, data8: bytes, payload: bytes = b"", chunk: int = 0xFF):
        span = 1 + (len(payload) + 31) // 32
        if self.slot + span > 126:
            self.page += 1
            self.slot = 0
        head = bytes([ns, typ, span, chunk])
        keyb = key.encode().ljust(16, b"\0")
        ent = head + struct.pack("<I", crc(head + keyb + data8)) + keyb + data8
        off = 64 + self.slot * 32
        pg = self.pages[self.page]
        pg[off:off + 32] = ent
        pg[off + 32:off + 32 + len(payload)] = payload
        for i in range(span):
            self._state(self.page, self.slot + i, 0b10)
        where = (self.page, self.slot, span)
        self.slot += span
        self.used.add(self.page)
        return where

    def namespace(self, name: str) -> int:
        if name not in self.ns:
            idx = len(self.ns) + 1
            self._write(0, 0x01, name, bytes([idx]) + b"\xFF" * 7)
            self.ns[name] = idx
        return self.ns[name]

    def set_int(self, ns: str, key: str, typ: int, value: int):
        fmt = {0x01: "<B", 0x11: "<b", 0x02: "<H", 0x12: "<h", 0x04: "<I", 0x14: "<i", 0x08: "<Q", 0x18: "<q"}[typ]
        return self._write(self.namespace(ns), typ, key, struct.pack(fmt, value).ljust(8, b"\xFF"))

    def set_str(self, ns: str, key: str, text: str):
        payload = text.encode() + b"\0"
        return self._write(self.namespace(ns), 0x21, key, struct.pack("<HHI", len(payload), 0xFFFF, crc(payload)), payload)

    def set_blob_v1(self, ns: str, key: str, data: bytes):
        return self._write(self.namespace(ns), 0x41, key, struct.pack("<HHI", len(data), 0xFFFF, crc(data)), data)

    def set_blob(self, ns: str, key: str, data: bytes, chunk_size: int = 4000, start: int = 0):
        idx = self.namespace(ns)
        chunks = [data[i:i + chunk_size] for i in range(0, len(data), chunk_size)] or [b""]
        for n, c in enumerate(chunks):
            self._write(idx, 0x42, key, struct.pack("<HHI", len(c), 0xFFFF, crc(c)), c, chunk=start + n)
        return self._write(idx, 0x48, key, struct.pack("<IBBH", len(data), len(chunks), start, 0xFFFF))

    def erase(self, where):
        page, slot, span = where
        for i in range(span):
            self._state(page, slot + i, 0b00)

    def image(self) -> bytes:
        for i, pg in enumerate(self.pages):
            if i in self.used:
                hdr = struct.pack("<II", 0xFFFFFFFE if i == self.page else 0xFFFFFFFC, i) + b"\xFE" + b"\xFF" * 19
                pg[0:32] = hdr + struct.pack("<I", crc(hdr[4:28]))
        return b"".join(bytes(p) for p in self.pages)


# ----------------------------------------------------------------------------- the synthetic device

BOARD = "sp-esp32-s3-1.28-box"
SECRETS = {
    "wifi password": "S3cr3t-WiFi-Pa55!",
    "erased old wifi password": "0ldErasedPassw0rd",
    "second wifi password": "An0ther#Passw0rd",
    "mqtt password": "mqttSignature+abc123XYZ==",
    "mqtt username": "eyJpcCI6IjEuMi4zLjQifQ==",
    "mqtt client id": "GID_test@@@ac_a7_04_22_9d_70@@@clientpart",
    "websocket token": "test-token-9f8e7d6c5b4a",
    "url query secret": "QUERYSECRET123456",
    "board uuid": "8a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
    "token under an innocent key": "ZXhhbXBsZVNlY3JldFRva2VuMTIzNDU2",
    "password inside JSON": "JsonHiddenPw1",
    "url user info": "UrlUserPw99",
    "numeric pin": "4829137766",
    "vendor device secret": "dEv1ceSecretValue",
}
PMK = bytes(range(0xA0, 0xC0))
VISIBLE = ["TestNet-2G", "Guest Net", "http://ota.example.net/xiaozhi/ota/", "mqtt.example.net:8883",
           "device-server", "dark", "h.example.net", "proxy.example.net:8080"]


def build_nvs() -> bytes:
    w = NvsWriter(6)
    old = w.set_str("wifi", "password", SECRETS["erased old wifi password"])
    w.erase(old)
    w.set_str("wifi", "ssid", "TestNet-2G")
    w.set_str("wifi", "password", SECRETS["wifi password"])
    w.set_str("wifi", "ssid1", "Guest Net")
    w.set_str("wifi", "password1", SECRETS["second wifi password"])
    w.set_str("wifi", "ota_url", "http://ota.example.net/xiaozhi/ota/")
    w.set_blob("nvs.net80211", "sta.ssid", struct.pack("<I", 10) + b"TestNet-2G".ljust(32, b"\0"))
    w.set_blob("nvs.net80211", "sta.pswd", SECRETS["wifi password"].encode().ljust(65, b"\0"))
    w.set_blob("nvs.net80211", "sta.pmk", PMK)
    w.set_int("nvs.net80211", "sta.authmode", 0x01, 3)
    w.set_int("nvs.net80211", "opmode", 0x01, 1)
    w.set_blob("phy", "cal_data", bytes((i * 7) & 0xFF for i in range(1904)), chunk_size=700)   # 3 chunks
    w.set_blob_v1("phy", "cal_mac", bytes.fromhex("aca704229d70"))
    w.set_int("phy", "cal_version", 0x04, 4660)
    w.set_str("mqtt", "endpoint", "mqtt.example.net:8883")
    w.set_str("mqtt", "client_id", SECRETS["mqtt client id"])
    w.set_str("mqtt", "username", SECRETS["mqtt username"])
    w.set_str("mqtt", "password", SECRETS["mqtt password"])
    w.set_str("mqtt", "publish_topic", "device-server")
    w.set_str("websocket", "url", "wss://api.example.net/xiaozhi/v1/?token=" + SECRETS["url query secret"])
    w.set_str("websocket", "token", SECRETS["websocket token"])
    w.set_int("websocket", "version", 0x14, 3)
    w.set_str("board", "uuid", SECRETS["board uuid"])
    w.set_int("audio", "output_volume", 0x14, 70)
    w.set_str("display", "theme", "dark")
    w.set_str("misc", "note", SECRETS["token under an innocent key"])
    w.set_str("misc", "cfg", '{"server":"h.example.net","password":"%s"}' % SECRETS["password inside JSON"])
    w.set_str("misc", "proxy", "http://user:%s@proxy.example.net:8080/x" % SECRETS["url user info"])
    w.set_int("misc", "pin", 0x08, int(SECRETS["numeric pin"]))
    w.set_str("vendor", "device_secret", SECRETS["vendor device secret"])
    w.set_str("vendor", "empty", "")
    w.set_blob("big", "filler", bytes(200) * 40, chunk_size=3000)           # pushes data onto later pages
    w.set_int("big", "after", 0x18, -5)
    return w.image()


V2_STRINGS = (b'{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"' + BOARD.encode()
              + b'","version":"\0esp32s3\0' + BOARD.encode() + b"/\0After board init\0" + BOARD.encode()
              + b"\0./main/boards/spotpear/" + BOARD.encode() + b"/" + BOARD.encode() + b".cc\0"
              + b"https://api.tenclass.net/xiaozhi/ota/\0http://192.168.4.1\0")
V1_STRINGS = (b'{"type":"' + BOARD.encode() + b'",\0"name":"' + BOARD.encode() + b'",\0' + BOARD.encode() + b"/\0"
              + b"./main/boards/" + BOARD.encode() + b"/" + BOARD.encode() + b".cc\0"
              + b"https://api.tenclass.net/xiaozhi/ota/\0wss://api.tenclass.net/xiaozhi/v1/\0")

LAYOUT = [("nvs", 1, 0x02, 0x9000, 0x6000), ("otadata", 1, 0x00, 0xF000, 0x2000), ("phy_init", 1, 0x01, 0x11000, 0x1000),
          ("ota_0", 0, 0x10, 0x20000, 0x100000), ("ota_1", 0, 0x11, 0x120000, 0x100000),
          ("model", 1, 0x82, 0x220000, 0x40000), ("assets", 1, 0x82, 0x260000, 0x100000)]
FLASH = 0x400000


def build_flash(otadata=None) -> bytearray:
    flash = bytearray(b"\xFF" * FLASH)

    def put(off: int, data: bytes):
        flash[off:off + len(data)] = data

    put(0, make_bootloader())
    put(0x8000, make_table(LAYOUT))
    put(0x9000, build_nvs())
    od = otadata if otadata is not None else (ota_entry(1, 2), ota_entry(2))
    put(0xF000, od[0])
    put(0x10000, od[1])
    put(0x20000, make_app("2.5.2", V2_STRINGS))
    put(0x120000, make_app("1.6.0", V1_STRINGS))
    models = struct.pack("<I", 1) + b"wn9_nihaoxiaozhi_tts".ljust(32, b"\0") + struct.pack("<I", 1) \
        + b"wn9_data".ljust(32, b"\0") + struct.pack("<II", 80, 16) + bytes(16)
    put(0x220000, models)
    table = b"index.json".ljust(32, b"\0") + struct.pack("<IIHH", 20, 0, 0, 0)
    blob = table + b"ZZ" + b'{"version":1}'.ljust(18, b" ")
    put(0x260000, struct.pack("<III", 1, sum(blob) & 0xFFFF, len(blob)) + blob)
    return flash


# ----------------------------------------------------------------------------- running the tools

def run(tool: str, *args, env_extra=None):
    env = dict(os.environ)
    env.pop("XZ_SECRETS_TO_PIPE", None)
    env.update(env_extra or {})
    p = subprocess.run([sys.executable, "-I", "-B", os.path.join(HERE, tool)] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=300)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def squeeze(text: str) -> str:
    """Collapse runs of blanks so checks do not depend on column alignment."""
    return re.sub(r"[ \t]+", " ", text)


def line_with(out: str, needle: str) -> str:
    return next((ln for ln in out.splitlines() if needle in ln), "")


def test_primitives():
    print("primitives")
    check(E.esp_crc32(struct.pack("<I", 1)) == 0x4743989A, "otadata CRC of sequence 1 is the well-known 0x4743989a")
    data = os.urandom(70001)
    naive = 0
    for b in data:
        naive ^= b
    check(E.xor_fold(data) == naive, "fast XOR checksum equals the byte-by-byte one")

    def pick(e0, e1, n=2, factory=False):
        ents = E.parse_otadata(e0.ljust(0x1000, b"\xFF") + e1.ljust(0x1000, b"\xFF"))
        return E.select_boot(ents, n, factory)

    blank = b"\xFF" * 32
    check(pick(blank, blank).index == 0, "blank otadata, no factory -> ota_0")
    check(pick(blank, blank, factory=True).index == E.FACTORY_INDEX, "blank otadata + factory app -> factory")
    check(pick(ota_entry(1), blank).index == 0, "sequence 1 -> ota_0")
    check(pick(ota_entry(3), ota_entry(4)).index == 1, "sequences 3 and 4 -> (4-1) mod 2 = ota_1")
    check(pick(ota_entry(4), ota_entry(3)).index == 1, "the higher sequence wins whichever copy holds it")
    check(pick(ota_entry(3), ota_entry(4, good_crc=False)).index == 0, "a copy with a bad CRC is ignored")
    check(pick(ota_entry(3), ota_entry(4, state=4)).index == 0, "a copy in state ABORTED is ignored")
    check(pick(ota_entry(7, good_crc=False), blank).index == E.FACTORY_INDEX, "only a bad-CRC copy -> factory/fallback order")
    check(pick(ota_entry(5), ota_entry(4), n=3).index == 1, "three slots: (5-1) mod 3 = ota_1")
    check(pick(ota_entry(2), blank).order == [1, 0, -1], "fallback order from ota_1 is ota_1, ota_0, factory")


def test_analyze(tmp: str, source):
    print("analyze: synthetic device image, default (redacted) output")
    img = os.path.join(tmp, "device.bin")
    flash = build_flash()
    with open(img, "wb") as f:
        f.write(flash)
    src = ["--source", source] if source else []
    rc, raw, err = run("analyze_flash_image.py", img, *src)
    out = squeeze(raw)
    check(rc == 0, "exit status 0 on a healthy image (got %d) %s" % (rc, err.strip()[:200]))
    for what, value in SECRETS.items():
        check(value not in out and value not in err, "secret not printed: %s" % what)
    check(PMK.hex() not in out.replace(" ", ""), "secret not printed: PMK bytes (hex)")
    for value in VISIBLE:
        check(value in out, "non-secret value is shown: %s" % value)
    check("1904 bytes" in line_with(out, "cal_data"), "3-chunk v2 blob reassembled to its full 1904 bytes")
    check("incomplete" not in out and "CRC mismatch" not in out, "no NVS entry reported incomplete or corrupt")
    check("8000 bytes" in line_with(out, "filler"), "blob spanning NVS pages reassembled (8000 bytes)")
    check(line_with(out, " after i64 ").rstrip().endswith("-5"), "signed 64-bit value decoded (-5)")
    check("70" in line_with(out, "output_volume"), "i32 value decoded (70)")
    check('SSID "TestNet-2G"' in line_with(out, "sta.ssid"), "ESP-IDF sta.ssid blob decoded to the SSID")
    check("wifi/password" in out and "erased items" in out, "erased entry listed by name only")
    check(line_with(out, "copy 0 @").find("ota_seq 1 ") > 0 and "VALID" in line_with(out, "copy 0 @"), "otadata copy 0: sequence 1, VALID")
    check("ota_1" in line_with(out, "selected:"), "otadata sequence 2 selects ota_1")
    check("ota_1 (its image is valid)" in line_with(out, "would boot:"), "ota_1 would boot")
    check("md5:" in out and "valid (" in line_with(out, "md5:"), "partition table MD5 valid")
    check(out.count("checksum: ok") == 3 and out.count("sha256: ok") == 3, "bootloader + 2 apps: checksum and SHA-256 ok")
    check("xiaozhi 2.5.2" in line_with(out, "app ota_0:") and "xiaozhi 1.6.0" in line_with(out, "app ota_1:"), "both app descriptors read")
    check(out.count("BOARD_NAME: " + BOARD) == 2 and (not source or out.count("BOARD_TYPE: " + BOARD) == 2),
          "board name%s found in the v2-style and the v1-style app" % ("/type" if source else ""))
    check('board JSON literal {"type":"%s",' % BOARD in out, 'v1-style {"type":"..."} literal recognised')
    check("built from: main/boards/%s " % BOARD in out and "built from: main/boards/spotpear/%s " % BOARD in out, "source directories read from assert paths")
    check("http://ota.example.net/xiaozhi/ota/" in line_with(out, "OTA URL:") and "overrides" in line_with(out, "OTA URL:"), "NVS wifi/ota_url reported as overriding the baked-in URL")
    check("STORED" in line_with(out, "WiFi credentials:"), "WiFi credentials reported as stored")
    check('"TestNet-2G" - password stored (17 chars, not shown)' in out, "WiFi summary: SSID + password length only")
    check("ESP-SR model pack" in out and "wn9_nihaoxiaozhi_tts" in out, "ESP-SR model partition recognised")
    check("xiaozhi assets image: 1 files" in out and "checksum ok" in line_with(out, "xiaozhi assets image"), "assets partition recognised, checksum ok")
    check("no problems found" in line_with(out, "result:"), "summary says no problems")
    if source:
        check(out.count("verdict: CONFIRMED") == 2 and "same board is main/boards/spotpear/" in out
              and out.count("older directory layout") == 1,
              "source-tree cross-check: both apps confirmed, the v1-style one mapped to the regrouped directory")

    print("analyze: --secrets")
    rc, out2, err2 = run("analyze_flash_image.py", img, "--secrets")
    check(rc == 2 and "refusing --secrets" in err2, "--secrets is refused when stdout is not a terminal")
    check(not any(v in out2 + err2 for v in SECRETS.values()), "... and nothing secret was printed by the refusal")
    rc, out3, _ = run("analyze_flash_image.py", img, "--secrets", env_extra={"XZ_SECRETS_TO_PIPE": "1"})
    shown = [w for w, v in SECRETS.items() if v in out3]
    check(rc == 0 and len(shown) == len(SECRETS) - 1 and "erased old wifi password" not in shown,
          "--secrets (forced) prints every live secret, and still not the erased one (%d/%d shown)" % (len(shown), len(SECRETS) - 1))

    print("analyze: damaged images")
    bad = bytearray(flash)
    bad[0x80D0] ^= 0xFF
    p = os.path.join(tmp, "bad-md5.bin")
    open(p, "wb").write(bad)
    rc, o, _ = run("analyze_flash_image.py", p)
    o = squeeze(o)
    check(rc == 3 and "INVALID" in line_with(o, "md5:") and "PROBLEM" in o, "broken partition-table MD5 -> reported, exit 3")

    bad = bytearray(flash)
    bad[0x120000 + 0x900] ^= 0x01
    p = os.path.join(tmp, "bad-app.bin")
    open(p, "wb").write(bad)
    rc, o, _ = run("analyze_flash_image.py", p)
    o = squeeze(o)
    check(rc == 3 and "MISMATCH" in o and "ota_0 - FALLBACK" in line_with(o, "would boot:"),
          "one flipped bit in the selected app -> checksum+hash mismatch, fallback to ota_0, exit 3")

    bad = bytearray(flash)
    bad[0x20000 + 0x900] ^= 0x01
    p = os.path.join(tmp, "bad-inactive.bin")
    open(p, "wb").write(bad)
    rc, o, _ = run("analyze_flash_image.py", p)
    o = squeeze(o)
    check(rc == 0 and "MISMATCH" in o and "ota_1 (its image is valid)" in line_with(o, "would boot:"),
          "damage in the slot that is NOT selected -> noted, still exit 0")

    p = os.path.join(tmp, "merged.bin")
    open(p, "wb").write(build_flash(otadata=(b"\xFF" * 32, b"\xFF" * 32))[:0x20000 + 0x2000])
    rc, o, _ = run("analyze_flash_image.py", p)
    o = squeeze(o)
    check(rc == 3 and "runs past the end of file" in o and "not in this file" in o,
          "file cut inside the selected app -> truncated image reported, other partitions 'not in this file', exit 3")

    p = os.path.join(tmp, "short.bin")
    open(p, "wb").write(flash[:0x5000])
    rc, o, _ = run("analyze_flash_image.py", p)
    o = squeeze(o)
    check(rc == 3 and "no partition table found" in o, "file that ends before the partition table -> reported, exit 3")

    p = os.path.join(tmp, "noise.bin")
    open(p, "wb").write(os.urandom(70000).replace(b"\xE9", b"\x00"))
    rc, o, e = run("analyze_flash_image.py", p)
    check(rc == 3 and "NOT an ESP image" in o and "Traceback" not in e, "random data -> clean report, no crash, exit 3")
    return img


def test_compare(tmp: str, img: str):
    if not os.path.exists(os.path.join(HERE, "compare_images.py")):
        print("compare: compare_images.py not present - skipped")
        return
    print("compare")
    flash = bytearray(open(img, "rb").read())
    rc, o, _ = run("compare_images.py", img, img)
    check(rc == 0 and "DIFFERS" not in o, "an image compared with itself: nothing differs, exit 0")

    other = bytearray(flash)
    other[0x9000 + 0x123] ^= 0xFF           # nvs
    other[0x120000 + 0x4567] ^= 0xFF        # ota_1
    other[0x120000 + 0x4999] ^= 0xFF
    p = os.path.join(tmp, "changed.bin")
    open(p, "wb").write(other)
    rc, o, _ = run("compare_images.py", img, p)
    nvs, ota1, ota0 = line_with(o, " nvs "), line_with(o, " ota_1 "), line_with(o, " ota_0 ")
    check(rc == 2, "differences -> exit 2 (got %d)" % rc)
    check("DIFFERS" in nvs and "0x009123" in nvs, "nvs: differs, first difference at 0x009123")
    check("DIFFERS" in ota1 and "0x124567" in ota1 and "2 bytes" in ota1, "ota_1: differs at 0x124567, 2 bytes differ")
    check("identical" in ota0, "ota_0: identical")

    p2 = os.path.join(tmp, "written.bin")
    open(p2, "wb").write(flash[:0x20000 + 0x5000])
    rc, o, _ = run("compare_images.py", p2, img)
    check(rc == 0 and "beyond end of" in line_with(o, " ota_1 ") and "identical" in line_with(o, " ota_0 "),
          "short file A vs full B: overlap identical, the rest 'beyond end of file', exit 0")
    rc, o, _ = run("compare_images.py", p2, p)
    check(rc == 2 and "DIFFERS" in line_with(o, " nvs "), "short file A vs changed B: nvs differs, exit 2")
    for value in SECRETS.values():
        if value in o:
            check(False, "compare output must never contain image contents")
            break
    else:
        check(True, "compare output contains no NVS contents")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", help="xiaozhi-esp32 checkout (enables the board cross-check assertions)")
    ap.add_argument("--keep", action="store_true", help="keep the temporary directory with the synthetic images")
    args = ap.parse_args()
    source = args.source if args.source and os.path.isdir(os.path.join(args.source, "main", "boards")) else None
    tmp = tempfile.mkdtemp(prefix="xz-selftest-")
    try:
        test_primitives()
        img = test_analyze(tmp, source)
        test_compare(tmp, img)
    finally:
        if args.keep:
            print("kept: %s" % tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print()
    if FAILS:
        print("RESULT: %d FAILED, %d passed" % (len(FAILS), PASSES))
        for f in FAILS:
            print("  failed: %s" % f)
        return 1
    print("RESULT: all %d checks passed" % PASSES)
    return 0


if __name__ == "__main__":
    sys.exit(main())
