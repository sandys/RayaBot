#!/usr/bin/env python3
"""analyze_flash_image.py — the engine of scripts/30-analyze-flash-image.sh.

    python3 -I -B analyze_flash_image.py IMAGE.bin [--source DIR] [--secrets]

Reads a raw ESP32 flash image that starts at flash offset 0 (a full dump, or a
"merged binary") and prints what is in it: bootloader, partition table, otadata /
boot decision, every app partition (validity, descriptor, which xiaozhi board it was
built for, baked-in URLs), NVS contents, the other data partitions, unallocated
space, and a summary. Parsing is in espflash.py (same directory); this file only
decides what to print and what to withhold.

Privacy: NVS holds WiFi passwords and server tokens. Every NVS value goes through
Redactor below, which by default prints the type and length only for anything that
looks like a credential (see the rules there). --secrets prints raw values and is
refused unless stdout is a terminal, so they cannot end up in a log, a pipe or a
captured transcript by accident (XZ_SECRETS_TO_PIPE=1 overrides that deliberately).

Exit status: 0 = analysed, nothing wrong; 3 = analysed, problems found (listed in
the summary); 1/2 = could not run (bad arguments, unreadable file).
"""

import argparse
import hashlib
import io
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import espflash as E  # noqa: E402

# ----------------------------------------------------------------------------- redaction

# Key names that mean "credential or personal identifier" (case-insensitive substring match).
_SENSITIVE_KEY = re.compile(
    r"pass|pswd|pwd|psk|pmk|wpa|wep|secret|token|key|cred|cert|priv|signature|hmac|auth|seed|salt|"
    r"nonce|cookie|session|bearer|jwt|otp|pincode|uuid|client_?id|device_?id|user|login|account|"
    r"licen[sc]e|serial|imei|imsi|iccid|phone|mobile|email|apinfo|bssid|owe_data|"
    r"(^|[._-])(pin|sig|sign|sn|ak|sk|did)($|[._-])", re.I)
# ... except these, which contain such a word but are plain enumerations / flags.
_HARMLESS_KEY = re.compile(r"^(sta\.authmode|ap\.authmode|sta\.minauth|bssid\.set)$", re.I)
# Namespaces the xiaozhi server fills with connection credentials: only these keys are shown.
_CREDENTIAL_NAMESPACES = {
    "mqtt": {"endpoint", "publish_topic", "subscribe_topic", "keepalive", "version"},
    "websocket": {"url", "version"},
}
_SSID_KEY = re.compile(r"^(ssid\d*|sta\.ssid|ap\.ssid)$")
_URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>\\]+")
_ASSIGN = re.compile(r"(?i)\b(pass(?:word|wd)?|pwd|token|secret|key|sig(?:nature)?|auth)(\s*[=:]\s*)([^\s&;,\"'<]+)")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def token_like(text: str) -> bool:
    """Heuristic: does this look like a random credential rather than a word, name or path?"""
    if _UUID.match(text):
        return True
    if text.startswith("eyJ") and text.count(".") >= 2:            # JWT
        return True
    for piece in re.split(r"[-_.:/@ ]", text):
        if len(piece) >= 16 and re.fullmatch(r"[A-Za-z0-9+=]+", piece):
            classes = sum(bool(re.search(p, piece)) for p in (r"[a-z]", r"[A-Z]", r"[0-9]"))
            if classes >= 2:
                return True
    return False


class Redactor:
    """The one place NVS values (and URLs taken from images) are turned into text."""

    def __init__(self, reveal: bool):
        self.reveal = reveal
        self.withheld = 0

    def _hide(self, what: str) -> str:
        self.withheld += 1
        return "<redacted: %s>" % what

    @staticmethod
    def key_sensitive(namespace: str, key: str) -> bool:
        if _HARMLESS_KEY.match(key):
            return False
        return bool(_SENSITIVE_KEY.search(key))

    def scrub_url(self, url: str, paths: bool = True) -> str:
        """Keep scheme, host and plain path; drop userinfo, query values and (paths=True) token-like
        path parts. URLs that are constants of a firmware build are scrubbed with paths=False."""
        if self.reveal:
            return url
        m = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$", url)
        if not m:
            return url
        scheme, authority, path, query, frag = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
        if "@" in authority:
            authority = self._hide("user info") + "@" + authority.rsplit("@", 1)[1]
        segs = [self._hide("%d chars" % len(s)) if paths and token_like(s) else s for s in path.split("/")]
        out = scheme + authority + "/".join(segs)
        if query:
            names = [p.split("=", 1)[0] for p in query[1:].split("&") if p]
            out += "?" + "&".join("%s=%s" % (n, self._hide("value")) for n in names)
        if frag:
            out += "#" + self._hide("fragment")
        return out

    def scrub_text(self, text: str) -> str:
        """Hide credentials embedded in an otherwise harmless string (URLs, JSON, key=value)."""
        if self.reveal:
            return text
        stripped = text.strip()
        if stripped[:1] in ("{", "["):
            try:
                return json.dumps(self._scrub_json(json.loads(stripped)), ensure_ascii=False, separators=(",", ":"))
            except ValueError:
                pass
        if token_like(text):
            return self._hide("%d chars, looks like a token" % len(text))
        text = _URL.sub(lambda m: self.scrub_url(m.group(0)), text)
        return _ASSIGN.sub(lambda m: m.group(1) + m.group(2) + self._hide("value"), text)

    def _scrub_json(self, node, key: str = ""):
        if isinstance(node, dict):
            return {k: self._scrub_json(v, str(k)) for k, v in node.items()}
        if isinstance(node, list):
            return [self._scrub_json(v, key) for v in node]
        if key and self.key_sensitive("", key) and not isinstance(node, bool) and node is not None:
            return self._hide("%d chars" % len(str(node)))
        if isinstance(node, str):
            return self.scrub_text(node)
        return node

    # --- NVS values -------------------------------------------------------------------

    def nvs_value(self, item) -> str:
        ns, key, value = item.namespace, item.key, item.value
        if item.type_name == "string":
            return self._string(ns, key, value)
        if item.type_name == "blob":
            return self._blob(ns, key, value)
        if self.reveal or not self.key_sensitive(ns, key):
            if item.type_name in ("u32", "u64") and value > 9:
                return "%d (0x%x)" % (value, value)
            return str(value)
        return self._hide("number")

    def _string(self, ns: str, key: str, text: str) -> str:
        n = len(text)
        if self.reveal:
            return '"%s"' % E.safe(text)
        if n == 0:
            return '"" (empty)'
        if _SSID_KEY.match(key):
            return '"%s"' % E.safe(text, 64)
        allowed = _CREDENTIAL_NAMESPACES.get(ns)
        if self.key_sensitive(ns, key) or (allowed is not None and key not in allowed):
            return self._hide("%d chars" % n)
        return '"%s"' % E.safe(self.scrub_text(text), 200)

    def _blob(self, ns: str, key: str, data: bytes) -> str:
        n = len(data)
        if self.reveal:
            head = data[:64].hex(" ")
            text = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in data[:64])
            return "%d bytes: %s%s |%s|" % (n, head, " ..." if n > 64 else "", text)
        if key in ("sta.ssid", "ap.ssid"):
            ssid = decode_ssid_blob(data)
            if ssid is not None:
                return '%d bytes: SSID "%s"' % (n, E.safe(ssid, 64)) if ssid else "%d bytes: no SSID set" % n
        if self.key_sensitive(ns, key):
            return self._hide("%d bytes" % n)
        return "%d bytes (binary; contents not shown)" % n


def decode_ssid_blob(data: bytes):
    """ESP-IDF stores sta.ssid / ap.ssid as u32 length + 32 bytes. None if it is something else."""
    if len(data) == 36:
        length = int.from_bytes(data[:4], "little")
        if length <= 32:
            return data[4:4 + length].decode("utf-8", "replace")
    if 0 < len(data) <= 33:
        return data.split(b"\0", 1)[0].decode("utf-8", "replace")
    return None


# ----------------------------------------------------------------------------- small helpers

def hx(n: int) -> str:
    return "0x%06x" % n


def blank_stats(buf: bytes):
    """(non-0xFF bytes, offset just past the last non-0xFF byte)."""
    used = len(buf) - buf.count(0xFF)
    return used, len(buf.rstrip(b"\xff"))


def coverage(p, flen: int) -> int:
    return max(0, min(p.end, flen) - p.offset)


class Report:
    def __init__(self):
        self.problems = []
        self.notes = []

    def problem(self, text: str):
        if text not in self.problems:
            self.problems.append(text)

    def note(self, text: str):
        if text not in self.notes:
            self.notes.append(text)


def section(title: str):
    print()
    print("=== %s ===" % title)


def kv(label: str, value: str):
    print("  %-17s %s" % (label + ":", value))


def print_segments(img):
    for s in img.segments:
        print("      #%d  load 0x%08x  size 0x%06x  file 0x%06x  %s" % (s.index, s.load_addr, s.size, s.file_off, s.region))


def describe_header(h):
    kv("chip id", "0x%04x %s" % (h.chip_id, h.chip_name))
    kv("SPI mode", "0x%02x %s" % (h.spi_mode, h.spi_mode_name))
    kv("SPI speed", "0x%x %s" % (h.spi_speed, h.spi_speed_name))
    size = h.flash_size_mb
    kv("flash size", "0x%x %s" % (h.spi_size, "%d MB" % size if size else "unknown"))
    kv("entry point", "0x%08x" % h.entry)
    kv("chip revision", "min v%d.%d, max v%d.%d" % (h.min_chip_rev_full // 100, h.min_chip_rev_full % 100,
                                                    h.max_chip_rev_full // 100, h.max_chip_rev_full % 100))


def describe_validity(img):
    """Lines for checksum / hash / length of a walked image; returns True if valid."""
    if img.error:
        kv("image", "INVALID - %s" % img.error)
        return False
    kv("image length", "0x%x (%d bytes), ends at %s" % (img.total_len, img.total_len, hx(img.offset + img.total_len)))
    kv("checksum", ("ok (0x%02x)" % img.checksum_stored) if img.checksum_ok
       else "MISMATCH: stored 0x%02x, computed 0x%02x" % (img.checksum_stored, img.checksum_calc))
    if img.hash_stored is None:
        kv("sha256", "none appended (hash_appended = %d)" % img.header.hash_appended)
    elif img.hash_ok:
        kv("sha256", "ok (appended hash %s... matches the image)" % img.hash_stored.hex()[:16])
    else:
        kv("sha256", "MISMATCH: appended %s..., computed %s..." % (img.hash_stored.hex()[:16], img.hash_calc.hex()[:16]))
    return img.valid


# ----------------------------------------------------------------------------- board identity

_PROTOCOL_WORDS = {"hello", "listen", "abort", "iot", "mcp", "tts", "stt", "llm", "goodbye", "system",
                   "alert", "custom", "start", "stop", "detect", "text", "audio", "function", "object"}


def identify_board(strings, cat, chip_name: str) -> dict:
    """Combine the string evidence of one app image into name / type / directory + cross-check lines."""
    r = {"name": None, "name_ev": [], "type": None, "type_ev": [], "dirs": [], "check": [],
         "confirmed": False, "moved": False, "known_types": [], "known_names": []}
    tokens = strings.tokens

    # where it was compiled from: main/boards/<dir>/<file> paths kept by asserts
    r["dirs"] = sorted(strings.board_dirs.items(), key=lambda kv_: (-len(kv_[1]), kv_[0]))

    # BOARD_NAME
    if strings.mcp_names:
        r["name"] = strings.mcp_names[0]
        r["name_ev"].append('MCP serverInfo literal "name":"%s"' % r["name"])
        if len(strings.mcp_names) > 1:
            r["name_ev"].append("other serverInfo names also present: %s" % ", ".join(strings.mcp_names[1:]))
    json_names = [n for n in strings.json_names if n not in _PROTOCOL_WORDS]
    if json_names:
        pick = next((n for n in json_names if cat and n in cat.by_name), json_names[0])
        if r["name"] is None:
            r["name"] = pick
        if pick == r["name"]:
            r["name_ev"].append('board JSON literal "name":"%s",' % pick)
    if cat:
        r["known_types"] = sorted(t for t in cat.by_type if t in tokens)
        r["known_names"] = sorted(n for n in cat.by_name if n in tokens)
        if r["name"] is None:
            ua = [n for n in r["known_names"] if tokens.get(n) in ("slash", "both")]
            pool = ua or r["known_names"]
            if len(pool) == 1:
                r["name"] = pool[0]
                r["name_ev"].append("the only board name of the source tree found as a string constant")
    if r["name"] and tokens.get(r["name"]) in ("slash", "both"):
        r["name_ev"].append('User-Agent prefix "%s/"' % r["name"])

    # BOARD_TYPE
    json_types = [t for t in strings.json_types if t not in _PROTOCOL_WORDS]
    if json_types:
        r["type"] = next((t for t in json_types if cat and t in cat.by_type), json_types[0])
        r["type_ev"].append('board JSON literal {"type":"%s",' % r["type"])
    if r["type"] is None and cat:
        via = None
        for d, _files in r["dirs"]:
            hit = d if d in cat.dirs else next(iter(cat.dirs_for_basename(d.split("/")[-1])), None)
            if hit and cat.dirs[hit]["type"] in tokens:
                via = (cat.dirs[hit]["type"], "config.json type of main/boards/%s, present as a string constant" % hit)
                break
        if via is None and r["name"] in cat.by_name:
            d = cat.by_name[r["name"]][0]
            if cat.dirs[d]["type"] in tokens:
                via = (cat.dirs[d]["type"], "config.json type of the board that owns build name %s, present as a string constant" % r["name"])
        if via is None and len(r["known_types"]) == 1:
            via = (r["known_types"][0], "the only board type of the source tree found as a string constant")
        if via:
            r["type"], ev = via
            r["type_ev"].append(ev)

    # cross-check against the source tree
    if cat is None:
        r["check"].append("source tree not available: board names not cross-checked")
        return r
    name_dirs = cat.by_name.get(r["name"], []) if r["name"] else []
    type_dirs = cat.by_type.get(r["type"], []) if r["type"] else []
    ok = True
    if r["name"]:
        if name_dirs:
            r["check"].append("name %s -> build of main/boards/%s (target %s)"
                              % (r["name"], name_dirs[0], cat.dirs[name_dirs[0]]["target"]))
        else:
            ok = False
            r["check"].append("name %s -> NOT a build name in this source tree" % r["name"])
    else:
        ok = False
        r["check"].append("no board name could be read from the image")
    if r["type"]:
        if type_dirs:
            same = " (same directory)" if name_dirs and type_dirs[0] == name_dirs[0] else ""
            r["check"].append("type %s -> main/boards/%s/config.json%s" % (r["type"], type_dirs[0], same))
            if name_dirs and type_dirs[0] != name_dirs[0]:
                ok = False
                r["check"].append("MISMATCH: name and type belong to different board directories")
        else:
            ok = False
            r["check"].append("type %s -> NOT a board type in this source tree" % r["type"])
    for d, _files in r["dirs"][:3]:
        if d in cat.dirs:
            agree = "" if not name_dirs or d == name_dirs[0] else "  (DIFFERENT from the name's directory)"
            r["check"].append("source paths main/boards/%s -> exists in the tree%s" % (d, agree))
            ok = ok and not agree
        else:
            moved = cat.dirs_for_basename(d.split("/")[-1])
            if moved:
                r["moved"] = True
                r["check"].append("source paths main/boards/%s -> same board is main/boards/%s in this tree "
                                  "(image was built from a different directory layout)" % (d, moved[0]))
            else:
                ok = False
                r["check"].append("source paths main/boards/%s -> NOT in this source tree" % d)
    owner = name_dirs[0] if name_dirs else (type_dirs[0] if type_dirs else None)
    if owner and chip_name != "unknown":
        target = str(cat.dirs[owner]["target"])
        if target.replace("-", "").lower() == chip_name.replace("-", "").lower():
            r["check"].append("chip %s == board target %s" % (chip_name, target))
        else:
            ok = False
            r["check"].append("MISMATCH: image is for %s, the board's target is %s" % (chip_name, target))
    r["confirmed"] = ok and bool(r["name"])
    return r


# ----------------------------------------------------------------------------- analysis of the parts

def analyze_app(buf: bytes, p, flen: int, cat, red: Redactor, rep: Report) -> dict:
    """Everything about one app partition; prints its section and returns a summary dict."""
    res = {"partition": p, "state": "absent", "valid": False, "desc": None, "ident": None,
           "ota_urls": [], "image": None}
    section("app partition %s @ %s (%s, %s)" % (E.safe(p.name), hx(p.offset), hx(p.size), E.fmt_size(p.size)))
    have = coverage(p, flen)
    if have == 0:
        kv("contents", "not in this file (the file ends at %s)" % hx(flen))
        return res
    data = buf[p.offset:p.offset + have]
    if E.is_blank(data):
        res["state"] = "blank"
        kv("contents", "blank: all 0xFF" + ("" if have == p.size else " in the %s that are in the file" % E.fmt_size(have)))
        return res
    img = E.parse_image(buf, p.offset, p.end)
    res["image"] = img
    res["state"] = "image"
    h = img.header
    if h is None or h.magic != E.ESP_IMAGE_MAGIC:
        used, extent = blank_stats(data)
        kv("contents", "NOT an app image (first byte 0x%02x); %d non-0xFF bytes, data up to +0x%x"
           % (data[0], used, extent))
        res["state"] = "garbage"
        return res
    describe_header(h)
    kv("segments", str(h.segment_count))
    print_segments(img)
    res["valid"] = describe_validity(img)
    if img.truncated:
        kv("note", "the file ends inside this image (only %s of the partition is in the file)" % E.fmt_size(have))
    if img.total_len:
        end = img.offset + img.total_len
        kv("fills", "%.1f%% of the partition (%s free)" % (100.0 * img.total_len / p.size, E.fmt_size(p.size - img.total_len)))
        tail = buf[end:p.offset + have]
        used, extent = blank_stats(tail)
        if used:
            kv("after image", "%d non-0xFF bytes up to %s - leftovers of an earlier, larger image"
               % (used, hx(end + extent)))
        elif have < p.size:
            kv("after image", "0xFF up to the end of the file at %s (rest of the partition is not in the file)" % hx(flen))
        else:
            kv("after image", "blank (0xFF) to the end of the partition")
    desc = E.parse_app_desc(buf, p.offset)
    res["desc"] = desc
    if desc is None:
        kv("app descriptor", "none (no 0xABCD5432 magic at image offset 0x20)")
    else:
        kv("project", E.safe(desc.project_name))
        kv("version", E.safe(desc.version))
        kv("compiled", "%s %s" % (E.safe(desc.date), E.safe(desc.time)))
        kv("ESP-IDF", E.safe(desc.idf_ver))
        kv("ELF sha256", desc.elf_sha256.hex())
        if desc.secure_version:
            kv("secure version", str(desc.secure_version))

    # strings: only inside the image itself, never the leftovers behind it
    scan_end = p.offset + (img.total_len if img.total_len else have)
    strings = E.scan_app_strings(buf[p.offset:scan_end])
    ident = identify_board(strings, cat, h.chip_name)
    res["ident"] = ident
    print("  board identity (string constants in this image):")
    print("    BOARD_NAME:  %s" % (ident["name"] or "not found"))
    for ev in ident["name_ev"]:
        print("                 <- %s" % ev)
    print("    BOARD_TYPE:  %s" % (ident["type"] or "not found"))
    for ev in ident["type_ev"]:
        print("                 <- %s" % ev)
    if ident["dirs"]:
        for d, files in ident["dirs"][:4]:
            print("    built from:  main/boards/%s  (paths kept by asserts: %s)" % (d, ", ".join(files[:6])))
    else:
        print("    built from:  no main/boards/... source paths in the image")
    if cat is not None:
        print("  cross-check with %s (version %s: %d board directories, %d types, %d build names):"
              % (os.path.relpath(cat.root), cat.version or "?", len(cat.dirs), len(cat.by_type), len(cat.by_name)))
        for line in ident["check"]:
            print("    %s" % line)
        print("    known board types present as string constants: %s"
              % (", ".join(ident["known_types"]) or "none"))
        print("    known build names present as string constants: %s"
              % (", ".join(ident["known_names"]) or "none"))
        if not ident["confirmed"]:
            verdict = "NOT fully confirmed by the source tree (see lines above)"
        elif ident["moved"]:
            verdict = ("CONFIRMED - board name, type and chip exist in the source tree; the image was built "
                       "from an older directory layout")
        else:
            verdict = "CONFIRMED - name, type, source paths and chip agree with the source tree"
        print("    verdict: %s" % verdict)
    else:
        for line in ident["check"]:
            print("    %s" % line)

    ota = [u for u in strings.urls if "ota" in u.lower()]
    res["ota_urls"] = ota
    default = cat.ota_url_default if cat else ""
    if ota:
        for u in ota:
            tag = ""
            if default:
                tag = "  (= CONFIG_OTA_URL default of the source tree)" if u == default \
                    else "  (source tree default is %s)" % default
            kv("OTA URL baked in", E.safe(red.scrub_url(u, paths=False), 200) + tag)
    else:
        kv("OTA URL baked in", "no http(s) URL containing 'ota' found")
    others = [u for u in strings.urls if u not in ota]
    if others:
        print("  other URLs in the image (%d):" % len(others))
        for u in others[:25]:
            print("    %s" % E.safe(red.scrub_url(u, paths=False), 160))
        if len(others) > 25:
            print("    ... and %d more" % (len(others) - 25))
    return res


def analyze_nvs(buf: bytes, p, flen: int, red: Redactor, rep: Report):
    section("NVS partition %s @ %s (%s)" % (E.safe(p.name), hx(p.offset), E.fmt_size(p.size)))
    have = coverage(p, flen)
    if have == 0:
        kv("contents", "not in this file")
        return None
    data = buf[p.offset:p.offset + have]
    dump = E.parse_nvs(data)
    if have < p.size:
        kv("note", "only %s of the partition is in the file" % E.fmt_size(have))
    if dump.blank:
        kv("contents", "blank: all 0xFF (%d pages). No settings, no WiFi credentials." % len(dump.pages))
        return dump
    print("  pages (4 KiB each; 126 entries of 32 bytes per page):")
    for pg in dump.pages:
        if pg.blank:
            print("    page %d @ %s: blank" % (pg.index, hx(p.offset + pg.index * E.NVS_PAGE)))
            continue
        print("    page %d @ %s: %-7s seq %-3d format v%d  header crc %s  entries: %d written, %d erased, %d free%s"
              % (pg.index, hx(p.offset + pg.index * E.NVS_PAGE), pg.state_name, pg.seq, 0xFF - pg.version + 1,
                 "ok" if pg.crc_ok else "BAD", pg.written, pg.erased, pg.empty,
                 (", %d UNREADABLE" % pg.bad) if pg.bad else ""))
    for prob in dump.problems:
        print("  PROBLEM: %s" % prob)
        rep.problem("NVS %s: %s" % (p.name, prob))
    names = [dump.namespaces[k] for k in sorted(dump.namespaces)]
    kv("namespaces", "%d: %s" % (len(names), ", ".join(E.safe(n) for n in names)))
    kv("live entries", str(len(dump.items)))
    current = None
    for it in dump.items:
        if it.namespace != current:
            current = it.namespace
            print("  [%s]" % E.safe(current))
        note = ("   !! %s" % it.note) if it.note else ""
        print("    %-16s %-7s %s%s" % (E.safe(it.key), it.type_name, red.nvs_value(it), note))
    used = {it.namespace for it in dump.items}
    for n in names:
        if n not in used:
            print("  [%s]" % E.safe(n))
            print("    (namespace exists, no live keys)")
    if dump.erased_keys:
        parts = ["%s/%s%s" % (E.safe(ns), E.safe(key), " x%d" % n if n > 1 else "")
                 for (ns, key), n in sorted(dump.erased_keys.items())]
        print("  erased items whose header is still readable in flash (superseded or deleted keys; values are never shown): %d"
              % sum(dump.erased_keys.values()))
        line = "   "
        for part in parts:
            if len(line) + len(part) > 110:
                print(line)
                line = "   "
            line += " " + part
        if line.strip():
            print(line)
    return dump


def wifi_credentials(dumps) -> list:
    """Lines answering 'are WiFi credentials stored?' - SSIDs yes, passwords only as present/length."""
    lines = []
    for pname, dump in dumps:
        if dump is None or dump.blank:
            continue
        # xiaozhi's own list (esp-wifi-connect SsidManager): namespace "wifi", ssid/password, ssid1/password1, ...
        for it in dump.items:
            m = re.match(r"^ssid(\d*)$", it.key)
            if it.namespace == "wifi" and m and it.type_name == "string":
                pw = dump.get("wifi", "password" + m.group(1))
                if pw is None:
                    pw_text = "no password entry"
                elif pw.type_name == "string" and len(pw.value) == 0:
                    pw_text = "password empty (open network)"
                else:
                    pw_text = "password stored (%d chars, not shown)" % pw.size
                lines.append('%s: xiaozhi WiFi list entry "%s" - %s' % (pname, E.safe(it.value, 64), pw_text))
        # ESP-IDF WiFi driver's own copy
        sta = dump.get("nvs.net80211", "sta.ssid")
        if sta is not None and sta.type_name == "blob":
            ssid = decode_ssid_blob(sta.value)
            pw = dump.get("nvs.net80211", "sta.pswd")
            n = len(pw.value.split(b"\0", 1)[0]) if pw is not None and pw.type_name == "blob" else 0
            if ssid:
                lines.append('%s: ESP-IDF WiFi driver station config "%s" - %s'
                             % (pname, E.safe(ssid, 64),
                                "password stored (%d chars, not shown)" % n if n else "no password stored"))
    return lines


def analyze_data_partition(buf: bytes, p, flen: int):
    have = coverage(p, flen)
    head = "  %-10s %-5s %-9s %s %-10s " % (E.safe(p.name)[:10], p.type_name, p.subtype_name, hx(p.offset), E.fmt_size(p.size))
    if have == 0:
        print(head + "not in this file")
        return
    data = buf[p.offset:p.offset + have]
    part = "" if have == p.size else " (only %s of it is in the file)" % E.fmt_size(have)
    if E.is_blank(data):
        print(head + "blank: all 0xFF" + part)
        return
    used, extent = blank_stats(data)
    print(head + "%d non-0xFF bytes (%.1f%%), data up to +0x%x%s" % (used, 100.0 * used / len(data), extent, part))
    indent = " " * len(head)
    assets = E.sniff_assets(data, p.size)
    if assets:
        chk = {True: "checksum ok", False: "CHECKSUM MISMATCH", None: "checksum not checkable (file ends first)"}[assets["checksum_ok"]]
        print(indent + "xiaozhi assets image: %d files, %s, %s" % (assets["files"], E.fmt_size(12 + assets["length"]), chk))
        names = [E.safe(n) for n in assets["names"]]
        line = indent + " "
        for n in names:
            if len(line) + len(n) > 118:
                print(line)
                line = indent + " "
            line += " " + n
        if line.strip():
            print(line)
        return
    models = E.sniff_srmodels(data)
    if models:
        print(indent + "ESP-SR model pack (srmodels.bin): %d models: %s" % (len(models), ", ".join(E.safe(m) for m in models)))
        return
    magic = E.sniff_magic(data, p.size)
    print(indent + ("recognised: %s" % magic if magic else "no known magic at the start of the partition"))


# ----------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description="Describe an ESP32 flash image (see the file header).")
    ap.add_argument("image")
    ap.add_argument("--source", help="xiaozhi-esp32 checkout used for cross-checks")
    ap.add_argument("--secrets", action="store_true", help="print NVS values unredacted (terminal only)")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    except (AttributeError, ValueError):
        pass
    if args.secrets and not sys.stdout.isatty() and os.environ.get("XZ_SECRETS_TO_PIPE") != "1":
        sys.stderr.write("refusing --secrets: stdout is not a terminal, the credentials would end up in a "
                         "file, pipe or transcript.\nRun it in an interactive terminal "
                         "(or set XZ_SECRETS_TO_PIPE=1 if you really mean it).\n")
        return 2
    try:
        with open(args.image, "rb") as f:
            buf = f.read()
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (args.image, e))
        return 1
    flen = len(buf)
    rep = Report()
    red = Redactor(args.secrets)
    cat = E.load_board_catalog(args.source) if args.source else None

    # ---- file
    section("flash image")
    kv("file", args.image)
    kv("size", "%d bytes (%s)" % (flen, E.fmt_size(flen)))
    kv("sha256", hashlib.sha256(buf).hexdigest())
    if flen == 0:
        print("  empty file - nothing to analyse")
        return 3
    used, extent = blank_stats(buf)
    kv("contents", "%d bytes are not 0xFF (%.1f%%); last such byte at %s" % (used, 100.0 * used / flen, hx(max(extent - 1, 0))))
    if args.secrets:
        print("  NOTE: --secrets is on: NVS values below are NOT redacted.")

    # ---- bootloader
    pt = E.find_partition_table(buf)
    bl_off = next((o for o in E.BOOTLOADER_OFFSETS if o < flen and buf[o] == E.ESP_IMAGE_MAGIC), None)
    section("second-stage bootloader @ %s" % (hx(bl_off) if bl_off is not None else "0x000000"))
    bl = None
    flash_bytes = None
    chip = None
    if bl_off is None:
        kv("magic", "0x%02x at offset 0 - NOT an ESP image (expected 0xE9; also none at 0x1000 / 0x2000)" % buf[0])
        rep.problem("no bootloader image at 0x0: the file does not start at flash offset 0, is encrypted, or is not a flash image")
    else:
        if bl_off:
            kv("note", "no image at 0x0; the bootloader sits at %s (ESP32/-S2: 0x1000, -P4/-C5: 0x2000)" % hx(bl_off))
        bl = E.parse_image(buf, bl_off, pt.offset if pt is not None and pt.offset > bl_off else None)
        h = bl.header
        chip = h.chip_name
        kv("magic", "0x%02X (ok)" % h.magic)
        describe_header(h)
        if h.flash_size_mb:
            flash_bytes = h.flash_size_mb << 20
        if h.chip_id not in E.CHIP_IDS:
            rep.problem("bootloader header has unknown chip id 0x%04x" % h.chip_id)
        kv("segments", str(h.segment_count))
        print_segments(bl)
        if not describe_validity(bl):
            rep.problem("bootloader image is not valid (%s)" % (bl.error or "checksum/hash mismatch"))
        bd = E.parse_bootloader_desc(buf, bl_off)
        if bd:
            kv("descriptor", "esp_bootloader_desc_t: bootloader version %d, ESP-IDF %s, built %s"
               % (bd.version, E.safe(bd.idf_ver), E.safe(bd.date_time)))
        else:
            ad = E.parse_app_desc(buf, bl_off)
            if ad:
                kv("descriptor", "esp_app_desc_t: %s %s, ESP-IDF %s, built %s %s"
                   % (E.safe(ad.project_name), E.safe(ad.version), E.safe(ad.idf_ver), E.safe(ad.date), E.safe(ad.time)))
            else:
                kv("descriptor", "none (bootloaders built with ESP-IDF older than 5.1 carry no descriptor)")
    if flash_bytes:
        if flen == flash_bytes:
            kind = "full dump: file size equals the %d MB flash size in the bootloader header" % (flash_bytes >> 20)
        elif flen < flash_bytes:
            kind = ("shorter than the %d MB flash the header declares: a merged binary or partial dump covering 0x0-%s"
                    % (flash_bytes >> 20, hx(flen)))
        else:
            kind = "LONGER than the %d MB flash size in the bootloader header" % (flash_bytes >> 20)
            rep.note("file is larger than the flash size in the bootloader header (header value may simply be stale)")
        kv("file vs flash", kind)

    # ---- partition table
    section("partition table @ %s" % (hx(pt.offset) if pt else hx(E.PT_OFFSET_DEFAULT)))
    if pt is None:
        if flen <= E.PT_OFFSET_DEFAULT:
            print("  not in this file (file ends at %s)" % hx(flen))
        else:
            print("  NOT FOUND: no partition magic (AA 50) at 0x8000 or at any 4 KiB boundary below 1 MiB")
        rep.problem("no partition table found")
    else:
        if pt.offset != E.PT_OFFSET_DEFAULT:
            kv("note", "table is at %s, not at the default 0x8000" % hx(pt.offset))
        print("  %-2s %-16s %-5s %-9s %-10s %-10s %-10s %-10s %-10s %s"
              % ("#", "name", "type", "subtype", "offset", "size", "end", "(size)", "flags", "in this file"))
        for p in pt.entries:
            have = coverage(p, flen)
            infile = "yes" if have == p.size else ("no" if have == 0 else "partly (%s)" % E.fmt_size(have))
            print("  %-2d %-16s %-5s %-9s %-10s %-10s %-10s %-10s %-10s %s"
                  % (p.index, E.safe(p.name), p.type_name, p.subtype_name, hx(p.offset), hx(p.size), hx(p.end),
                     E.fmt_size(p.size), p.flag_names or "-", infile))
        if pt.md5_present:
            if pt.md5_ok:
                kv("md5", "valid (%s)" % pt.md5_stored.hex())
            else:
                kv("md5", "INVALID: stored %s, computed %s" % (pt.md5_stored.hex(), pt.md5_calc.hex()))
                rep.problem("partition table MD5 does not match its entries")
        else:
            kv("md5", "no MD5 record in the table (built with --disable-md5sum, or damaged)")
            rep.note("partition table carries no MD5 record")
        for prob in pt.problems(flash_bytes):
            print("  PROBLEM: %s" % prob)
            rep.problem("partition table: %s" % prob)
        if cat is not None:
            hits, count = E.match_partition_csvs(pt, cat.root)
            kv("layout", ("identical to %s in %s" % (", ".join(hits), os.path.relpath(cat.root))) if hits
               else "matches none of the %d partition CSVs in %s/partitions" % (count, os.path.relpath(cat.root)))
        last = max((p.end for p in pt.entries), default=0)
        kv("extent", "partitions end at %s%s" % (hx(last), (" of a %d MB flash" % (flash_bytes >> 20)) if flash_bytes else ""))

    entries = pt.entries if pt else []
    apps = [p for p in entries if p.is_app]
    ota_parts = {p.ota_index: p for p in apps if p.ota_index is not None}
    factory = next((p for p in apps if p.subtype == 0x00), None)

    # ---- apps (analysed before otadata is printed, the boot decision needs their validity)
    app_results = {}
    app_text = io.StringIO()
    real_stdout = sys.stdout
    sys.stdout = app_text
    try:
        for p in apps:
            app_results[p.name] = analyze_app(buf, p, flen, cat, red, rep)
    finally:
        sys.stdout = real_stdout

    # ---- otadata
    otadata = next((p for p in entries if p.type == 0x01 and p.subtype == 0x00), None)
    choice = None
    boots = None
    if pt is not None:
        section("otadata / boot selection" + (" @ %s" % hx(otadata.offset) if otadata else ""))
        ents = []
        if otadata is None:
            print("  no otadata partition in the table")
        elif coverage(otadata, flen) == 0:
            print("  otadata is not in this file")
        else:
            ents = E.parse_otadata(buf[otadata.offset:otadata.offset + coverage(otadata, flen)])
            for i, e in enumerate(ents):
                where = hx(otadata.offset + i * E.SECTOR)
                if e is None:
                    print("  copy %d @ %s: not in this file" % (i, where))
                elif e.blank:
                    print("  copy %d @ %s: blank (all 0xFF) - never written" % (i, where))
                else:
                    print("  copy %d @ %s: ota_seq %d (0x%08x)  state %s (0x%x)  crc %s"
                          % (i, where, e.seq, e.seq, e.state_name, e.state,
                             "ok" if e.crc_ok else "BAD (stored 0x%08x, computed 0x%08x)" % (e.crc_stored, e.crc_calc)))
                    if e.state in (0, 1):
                        rep.note("otadata copy %d is %s: a bootloader built with app rollback marks such a slot "
                                 "ABORTED on the next reset unless the app confirmed itself" % (i, e.state_name))
        choice = E.select_boot(ents, len(ota_parts), factory is not None)

        def slot_part(idx):
            return factory if idx == E.FACTORY_INDEX else ota_parts.get(idx)

        sel = slot_part(choice.index)
        kv("selected", "%s  (%s)" % (E.safe(sel.name) if sel else "nothing bootable", choice.reason))
        if choice.active_copy is not None:
            kv("active copy", "otadata copy %d" % choice.active_copy)
        tried = []
        for idx in choice.order:
            part = slot_part(idx)
            if part is None:
                continue
            res = app_results.get(part.name, {})
            tried.append("%s=%s" % (part.name, "valid" if res.get("valid") else res.get("state", "?")))
            if res.get("valid"):
                boots = part
                break
        test = next((p for p in apps if p.subtype == 0x20), None)
        if boots is None and test is not None and app_results.get(test.name, {}).get("valid"):
            boots = test
        if boots is not None:
            if sel is not None and boots.name == sel.name:
                kv("would boot", "%s (its image is valid)" % E.safe(boots.name))
            else:
                kv("would boot", "%s - FALLBACK, tried in bootloader order: %s" % (E.safe(boots.name), ", ".join(tried)))
                rep.problem("the selected slot %s has no valid image; the bootloader would fall back to %s"
                            % (sel.name if sel else "(none)", boots.name))
        else:
            present = [r for r in app_results.values() if r["state"] != "absent"]
            if apps and not present:
                kv("would boot", "cannot tell: no app partition is inside this file")
                rep.note("no app partition is inside this file")
            else:
                kv("would boot", "NOTHING - no app partition holds a valid image (tried: %s)" % (", ".join(tried) or "none"))
                rep.problem("no bootable application: no app partition holds a valid image")

    # ---- apps (print what was captured)
    sys.stdout.write(app_text.getvalue())
    sel_part = None
    if choice is not None:
        sel_part = factory if choice.index == E.FACTORY_INDEX else ota_parts.get(choice.index)
    for name, res in app_results.items():
        img = res.get("image")
        if res["state"] in ("image", "garbage") and not res["valid"]:
            why = (img.error if img and img.error else "checksum/hash mismatch") if res["state"] == "image" else "not an ESP image"
            if boots is None or (sel_part is not None and sel_part.name == name):
                rep.problem("app partition %s does not hold a valid image (%s)" % (name, why))
            else:
                rep.note("app partition %s (not the selected slot) does not hold a valid image (%s)" % (name, why))
        if res["valid"] and bl is not None and bl.header and img.header.chip_id != bl.header.chip_id:
            rep.problem("app in %s is for %s but the bootloader is for %s" % (name, img.header.chip_name, bl.header.chip_name))

    # ---- NVS
    dumps = []
    before_nvs = red.withheld
    for p in entries:
        if p.type == 0x01 and p.subtype == 0x02:
            try:
                dumps.append((p.name, analyze_nvs(buf, p, flen, red, rep)))
            except Exception as e:                      # never let a parser bug dump raw data
                print("  could not decode this NVS partition: %s" % type(e).__name__)
                rep.problem("NVS partition %s could not be decoded (%s)" % (p.name, type(e).__name__))
    if red.withheld > before_nvs and not args.secrets:
        print()
        print("  %d values redacted above (credentials / identifiers). They are only printed with --secrets,"
              % (red.withheld - before_nvs))
        print("  which works in an interactive terminal only and is never written to logs/.")

    # ---- other data partitions
    others = [p for p in entries if not p.is_app and not (p.type == 0x01 and p.subtype in (0x00, 0x02))]
    if others:
        section("other partitions")
        print("  %-10s %-5s %-9s %-8s %-10s %s" % ("name", "type", "subtype", "offset", "size", "contents"))
        for p in others:
            analyze_data_partition(buf, p, flen)

    # ---- unallocated space
    if pt is not None:
        section("space outside partitions")
        regions = []
        if bl is not None and bl.total_len:
            regions.append((bl.offset, bl.offset + bl.total_len))
        regions.append((pt.offset, pt.offset + E.SECTOR))
        regions += [(p.offset, p.end) for p in entries]
        regions.sort()
        gaps = []
        pos = 0
        top = max(flash_bytes or 0, flen)
        for lo, hi in regions:
            if lo > pos:
                gaps.append((pos, lo))
            pos = max(pos, hi)
        if pos < top:
            gaps.append((pos, top))
        dirty = 0
        for lo, hi in gaps:
            have_hi = min(hi, flen)
            if lo >= flen:
                print("  %s-%s  %-10s not in this file" % (hx(lo), hx(hi), E.fmt_size(hi - lo)))
                continue
            used, extent = blank_stats(buf[lo:have_hi])
            tail = "" if have_hi == hi else " (file ends at %s)" % hx(flen)
            if used:
                dirty += 1
                print("  %s-%s  %-10s %d non-0xFF bytes, data up to %s%s" % (hx(lo), hx(hi), E.fmt_size(hi - lo), used, hx(lo + extent), tail))
            else:
                print("  %s-%s  %-10s blank (0xFF)%s" % (hx(lo), hx(hi), E.fmt_size(hi - lo), tail))
        if not gaps:
            print("  none: bootloader, partition table and partitions cover the whole flash")
        if dirty:
            rep.note("%d region(s) outside any partition contain data" % dirty)

    # ---- summary
    section("summary")
    if bl is not None and bl.header:
        h = bl.header
        kv("chip / flash", "%s, %s flash, %s %s (bootloader header)"
           % (h.chip_name, ("%d MB" % h.flash_size_mb) if h.flash_size_mb else "unknown-size", h.spi_mode_name, h.spi_speed_name))
        bd = E.parse_bootloader_desc(buf, bl.offset)
        kv("bootloader", "%s%s" % ("valid" if bl.valid else "INVALID",
                                   (", ESP-IDF %s, built %s" % (E.safe(bd.idf_ver), E.safe(bd.date_time))) if bd else ", no descriptor"))
    if pt is not None:
        kv("partitions", "%d: %s; MD5 %s" % (len(entries), ", ".join(E.safe(p.name) for p in entries),
                                             {True: "valid", False: "INVALID", None: "absent"}[pt.md5_ok]))
    if choice is not None:
        sel = factory if choice.index == E.FACTORY_INDEX else ota_parts.get(choice.index)
        kv("active slot", "%s%s" % (E.safe(sel.name) if sel else "none",
                                    "" if boots is None or (sel and boots.name == sel.name) else " (but would boot %s)" % boots.name))
    for p in apps:
        res = app_results[p.name]
        d = res["desc"]
        if res["state"] == "absent":
            text = "not in this file"
        elif res["state"] == "blank":
            text = "blank"
        elif d is not None:
            text = "%s %s, built %s %s, ESP-IDF %s - image %s" % (E.safe(d.project_name), E.safe(d.version), E.safe(d.date),
                                                                E.safe(d.time), E.safe(d.idf_ver), "valid" if res["valid"] else "INVALID")
        else:
            text = "no app descriptor - image %s" % ("valid" if res["valid"] else "INVALID")
        kv("app " + p.name, text)
    running = app_results.get(boots.name) if boots is not None else None
    if running is not None and running["ident"] is not None:
        ident = running["ident"]
        state = "confirmed against the source tree" if ident["confirmed"] else \
            ("not cross-checked (no source tree)" if cat is None else "NOT confirmed against the source tree")
        kv("board", "%s (type %s) - %s" % (ident["name"] or "unknown", ident["type"] or "unknown", state))
        baked = running["ota_urls"]
        override = None
        for _pname, dump in dumps:
            it = dump.get("wifi", "ota_url") if dump is not None else None
            if it is not None and it.type_name == "string" and it.value:
                override = it.value
        if override:
            kv("OTA URL", "%s  (NVS wifi/ota_url overrides the baked-in %s)"
               % (E.safe(red.scrub_url(override), 160), ", ".join(red.scrub_url(u, paths=False) for u in baked) or "none"))
        elif baked:
            kv("OTA URL", "%s  (baked into %s; no NVS override)" % (", ".join(red.scrub_url(u, paths=False) for u in baked), boots.name))
        else:
            kv("OTA URL", "none found in %s and no NVS override" % boots.name)
    if dumps:
        lines = wifi_credentials(dumps)
        if lines:
            kv("WiFi credentials", "STORED")
            for line in lines:
                print("  %-17s %s" % ("", line))
        elif all(d is None for _n, d in dumps):
            kv("WiFi credentials", "unknown: the NVS partition is not in this file")
        elif all(d is None or d.blank for _n, d in dumps):
            kv("WiFi credentials", "none: NVS is blank")
        else:
            kv("WiFi credentials", "none found (no wifi/ssid entry, no nvs.net80211/sta.ssid)")
    for n in rep.notes:
        kv("note", n)
    if rep.problems:
        for prob in rep.problems:
            kv("PROBLEM", prob)
        kv("result", "%d problem(s) found" % len(rep.problems))
        return 3
    kv("result", "no problems found in the parts that are in this file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
