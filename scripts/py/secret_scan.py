#!/usr/bin/env python3
"""secret_scan.py — the engine of scripts/90-check-secrets.sh: keep device secrets out of git.

    python3 -I -B secret_scan.py --repo DIR --backups DIR (--staged | --tracked)

What counts as a secret
    The value of every NVS key that scripts/30-analyze-flash-image.sh redacts (the same rules,
    imported from analyze_flash_image.py): WiFi passwords, MQTT/websocket credentials, tokens,
    the board UUID, client/device ids, ... read from the NVS partition(s) of every flash dump
    under --backups. Values stay in memory: the report names the file and the NVS namespace/key,
    never a value.

Also refused outright
    any path under backups/, and flash images (*.bin) larger than 64 KiB.

What is scanned (always the index version, i.e. exactly what would be committed)
    --staged   every file added or changed in the next commit
    --tracked  every tracked file

Exit status: 0 clean; 1 leak or forbidden path found; 2 could not run.
"""

import argparse
import glob
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import espflash as E  # noqa: E402
from analyze_flash_image import _CREDENTIAL_NAMESPACES, Redactor, token_like  # noqa: E402

NVS_TYPE, NVS_SUBTYPE = 0x01, 0x02
MAX_BIN = 64 * 1024
MIN_LEN = 6          # shorter values would match ordinary text; counted and reported, not searched
# Placeholder values that are public knowledge (vendor test setups ship them). Not secrets, and
# docs about server configuration legitimately quote them. Compared case-insensitively.
PUBLIC_DEFAULTS = {"test-token", "your-token", "12345678", "123456789", "1234567890", "87654321",
                   "00000000", "11111111", "88888888", "password", "password1", "changeme"}


def sensitive(ns: str, key: str, value) -> bool:
    """The redaction rule of analyze_flash_image.py, applied to one live NVS key."""
    if Redactor.key_sensitive(ns, key):
        return True
    allowed = _CREDENTIAL_NAMESPACES.get(ns)
    if allowed is not None and key not in allowed:
        return True
    return isinstance(value, str) and token_like(value)


def needles_from_dump(path: str, needles: dict, skipped: dict) -> None:
    """Add {needle bytes: "ns/key"} for one full flash dump. Values never leave this process;
    skipped["short"] / skipped["public"] count what is deliberately not searched."""
    with open(path, "rb") as f:
        data = f.read()
    table = E.find_partition_table(data)
    if table is None:
        return
    for p in table.entries:
        if p.type != NVS_TYPE or p.subtype != NVS_SUBTYPE or p.end > len(data):
            continue
        for item in E.parse_nvs(data[p.offset:p.end]).items:
            value = item.value
            if not sensitive(item.namespace, item.key, value):
                continue
            label = "%s/%s" % (item.namespace, item.key)
            if isinstance(value, str) and value.lower() in PUBLIC_DEFAULTS:
                skipped["public"] += 1
                continue
            if isinstance(value, str):
                forms = {value, value.lower(), value.upper()}
                found = {s.encode() for s in forms}
            elif isinstance(value, (bytes, bytearray)):
                raw = bytes(value)
                found = {raw, raw.rstrip(b"\0"), raw.hex().encode(), raw.hex().upper().encode()}
            else:
                continue                      # integers: not distinctive text
            for n in found:
                if len(n) >= MIN_LEN:
                    needles.setdefault(n, label)
                else:
                    skipped["short"] += 1


def hits(data: bytes, needle: bytes):
    """Offsets where needle occurs as a token of its own. An occurrence inside a longer run of
    letters, digits, '-' or '_' is a different identifier and does not count (e.g. a digit run
    inside the base64 alphabet, or a placeholder that a longer fake test token starts with)."""
    def word(b: int) -> bool:
        return 48 <= b <= 57 or 65 <= b <= 90 or 97 <= b <= 122 or b in (45, 95)
    out, i = [], data.find(needle)
    while i >= 0:
        j = i + len(needle)
        left_ok = not (word(needle[0]) and i > 0 and word(data[i - 1]))
        right_ok = not (word(needle[-1]) and j < len(data) and word(data[j]))
        if left_ok and right_ok:
            out.append(i)
        i = data.find(needle, i + 1)
    return out


def explain(path: str, data: bytes, needle: bytes, label: str, offsets) -> None:
    """Show where a hit is, with the value itself masked."""
    for off in offsets[:3]:
        line_no = data.count(b"\n", 0, off) + 1
        start = data.rfind(b"\n", 0, off) + 1
        end = data.find(b"\n", off)
        end = len(data) if end < 0 else end
        masked = data[start:off] + ("<NVS %s: %d chars>" % (label, len(needle))).encode() + data[off + len(needle):end]
        text = masked.decode("utf-8", "replace").strip()
        print("          %s:%d  %s" % (path, line_no, text[:160]))


def git(repo: str, *args: str) -> bytes:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser(description="Refuse commits that contain device secrets.")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--backups", required=True)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--tracked", action="store_true")
    ap.add_argument("--explain", action="store_true",
                    help="show the line of each hit, with the secret value masked")
    a = ap.parse_args()

    dumps = sorted(glob.glob(os.path.join(a.backups, "**", "*.bin"), recursive=True))
    needles: dict = {}
    skipped = {"short": 0, "public": 0}
    for d in dumps:
        try:
            needles_from_dump(d, needles, skipped)
        except Exception as e:  # report the kind of failure only: messages could quote data
            print("WARN      cannot read %s (%s); its secrets are not checked" % (os.path.basename(d), type(e).__name__))

    try:
        if a.staged:
            listing = git(a.repo, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRT")
        else:
            listing = git(a.repo, "ls-files", "-z")
    except subprocess.CalledProcessError:
        print("ERROR     %s is not a git repository" % a.repo)
        return 2
    paths = [p.decode("utf-8", "surrogateescape") for p in listing.split(b"\0") if p]

    problems = 0
    for path in paths:
        if path == "backups" or path.startswith("backups/"):
            print("FORBIDDEN %s: backups/ holds flash dumps with credentials" % path)
            problems += 1
            continue
        data = git(a.repo, "cat-file", "blob", ":" + path)
        if path.lower().endswith(".bin") and len(data) > MAX_BIN:
            print("FORBIDDEN %s: a %d-byte flash image; images belong in backups/, out/ or prebuilt/" % (path, len(data)))
            problems += 1
            continue
        found = {}
        for n, label in needles.items():
            offsets = hits(data, n)
            if offsets:
                found.setdefault(label, []).append((n, offsets))
        for label in sorted(found):
            print("LEAK      %s: contains the value of NVS %s (value not shown)" % (path, label))
            problems += 1
            if a.explain:
                for n, offsets in found[label]:
                    explain(path, data, n, label, offsets)

    labels = len(set(needles.values()))
    print("checked   %d %s file(s) against %d secret value form(s) (%d NVS keys) from %d dump(s)"
          % (len(paths), "staged" if a.staged else "tracked", len(needles), labels, len(dumps)))
    if skipped["short"] or skipped["public"]:
        print("skipped   %d value form(s) under %d chars, %d public placeholder value(s)"
              % (skipped["short"], MIN_LEN, skipped["public"]))
    if not dumps:
        print("WARN      no dumps under %s: only the path rules were applied" % a.backups)
    print("result    %s" % ("CLEAN" if problems == 0 else "BLOCKED: %d problem(s) above" % problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
