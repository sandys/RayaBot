#!/usr/bin/env python3
"""fetch_prebuilt.py — helper for scripts/31-fetch-prebuilt-firmware.sh.

It does the parts of the download that mean *interpreting untrusted data*:
the GitHub API answer, the release manifest and the ZIP archive. The shell
script does the network I/O (curl) and calls this file with `python3 -I`.

Sub-commands (all read-only except `unpack`, which only writes below DEST):

  release-info RELEASE.json
        one line: tag <TAB> html_url <TAB> published_at <TAB> commit
  support RELEASE.json
        lines "name <TAB> url <TAB> size <TAB> digest" for the helper assets
        that exist in the release (release-manifest.json, SHA256SUMS)
  select RELEASE.json BOARD [--manifest release-manifest.json]
        find the firmware asset for BOARD; one line:
        variant-name <TAB> asset-name <TAB> url <TAB> size <TAB> digest
        exit 3 with an explanation on stderr if there is no / no unique match
  list RELEASE.json [--manifest release-manifest.json]
        every firmware variant the release offers
  verify FILE --name ASSET [--size N] [--digest sha256:HEX] [--sums SHA256SUMS]
        check a downloaded file against what GitHub announced; exit 4 on mismatch
  unpack ZIP DEST
        extract ZIP into the (existing, empty) directory DEST, refusing anything
        that is not a plain file with a simple relative name; nothing is executed
  check-unpacked ZIP DIR
        are the files in DIR still identical to the ZIP members? exit 4 if not
  describe DIR
        sha256 / size / name of every file below DIR, plus a first-bytes hint

Every string that came from the network is validated before it is printed for
the shell to use (asset names: [A-Za-z0-9._+-] only; URLs: https on github.com
inside the expected repository).
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import zipfile

REPO = "78/xiaozhi-esp32"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$")
SAFE_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
URL_PREFIX = "https://github.com/%s/releases/download/" % REPO
SUPPORT_ASSETS = ("release-manifest.json", "SHA256SUMS")

MAX_ZIP_MEMBERS = 64
MAX_MEMBER_BYTES = 256 * 1024 * 1024      # a flash image is at most 32 MB here
MAX_TOTAL_BYTES = 512 * 1024 * 1024


def fail(code, msg):
    sys.stderr.write("fetch_prebuilt: %s\n" % msg)
    sys.exit(code)


def load_json(path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        fail(2, "cannot read JSON %s: %s" % (path, e))


def clean(text, limit=300):
    """Printable, single-line version of an untrusted string (for messages)."""
    text = str(text)
    out = "".join(c if 32 <= ord(c) < 127 else "?" for c in text)
    return out[:limit]


def release_assets(release):
    """Validated asset list of a GitHub release object."""
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        msg = release.get("message") if isinstance(release, dict) else None
        fail(2, "not a GitHub release object%s" % (": " + clean(msg) if msg else ""))
    assets = []
    for a in release["assets"]:
        if not isinstance(a, dict):
            continue
        name = a.get("name")
        url = a.get("browser_download_url")
        if not isinstance(name, str) or not SAFE_NAME.match(name):
            sys.stderr.write("fetch_prebuilt: ignoring asset with unsafe name %r\n" % clean(name))
            continue
        if (not isinstance(url, str) or not url.startswith(URL_PREFIX)
                or re.search(r"[\s\"'\\<>|`$;&]", url) or len(url) > 600):
            sys.stderr.write("fetch_prebuilt: ignoring asset %s: unexpected URL\n" % name)
            continue
        size = a.get("size")
        size = size if isinstance(size, int) and 0 <= size < 2 ** 40 else -1
        digest = a.get("digest")
        if not (isinstance(digest, str) and re.match(r"^sha256:[0-9a-f]{64}$", digest)):
            digest = "-"
        assets.append({"name": name, "url": url, "size": size, "digest": digest})
    return assets


def release_tag(release):
    tag = release.get("tag_name") if isinstance(release, dict) else None
    if not isinstance(tag, str) or not SAFE_TAG.match(tag):
        fail(2, "release has no usable tag_name")
    return tag


def manifest_variants(path):
    """[{board, name, full_name, target}] from release-manifest.json, or []."""
    if not path or not os.path.isfile(path):
        return []
    data = load_json(path)
    out = []
    for v in data.get("variants", []) if isinstance(data, dict) else []:
        if not isinstance(v, dict):
            continue
        rec = {}
        for key in ("board", "name", "full_name", "target"):
            val = v.get(key)
            rec[key] = val if isinstance(val, str) else ""
        if SAFE_NAME.match(rec["name"]) and SAFE_NAME.match(rec["full_name"]):
            out.append(rec)
    return out


def firmware_stems(tag, assets):
    """{stem: asset} for the firmware ZIPs, with a leading '<tag>_' removed."""
    stems = {}
    for a in assets:
        if not a["name"].lower().endswith(".zip"):
            continue
        stem = a["name"][:-4]
        if stem.startswith(tag + "_"):
            stem = stem[len(tag) + 1:]
        stems[stem] = a
    return stems


def cmd_release_info(args):
    rel = load_json(args.release)
    tag = release_tag(rel)
    html = rel.get("html_url")
    html = html if isinstance(html, str) and html.startswith("https://github.com/") else "-"
    print("\t".join([tag, clean(html), clean(rel.get("published_at") or "-", 40),
                     clean(rel.get("target_commitish") or "-", 64)]))


def cmd_support(args):
    rel = load_json(args.release)
    for a in release_assets(rel):
        if a["name"] in SUPPORT_ASSETS:
            print("\t".join([a["name"], a["url"], str(a["size"]), a["digest"]]))


def cmd_list(args):
    rel = load_json(args.release)
    tag = release_tag(rel)
    stems = firmware_stems(tag, release_assets(rel))
    variants = manifest_variants(args.manifest)
    if variants:
        print("%-44s %-10s %-44s %s" % ("--board NAME", "target", "source directory", "asset"))
        for v in sorted(variants, key=lambda v: v["name"]):
            a = stems.get(v["full_name"])
            print("%-44s %-10s %-44s %s" % (v["name"], clean(v["target"], 10), clean(v["board"], 44),
                                            a["name"] if a else "(asset missing)"))
        print("%d variants in release-manifest.json, %d firmware ZIPs in the release" % (len(variants), len(stems)))
    else:
        for stem in sorted(stems):
            print("%-52s %s" % (stem, stems[stem]["name"]))
        print("%d firmware ZIPs (this release has no release-manifest.json; names are asset names)" % len(stems))


def cmd_select(args):
    rel = load_json(args.release)
    tag = release_tag(rel)
    want = args.board
    stems = firmware_stems(tag, release_assets(rel))
    if not stems:
        fail(3, "release %s has no .zip assets at all" % tag)
    variants = manifest_variants(args.manifest)

    chosen = None      # (variant name, asset)
    how = ""
    if variants:
        hits = [v for v in variants if v["name"] == want]
        how = "release-manifest.json: build name"
        if not hits:
            hits = [v for v in variants if v["full_name"] == want]
            how = "release-manifest.json: full_name"
        if not hits:
            hits = [v for v in variants if v["board"] == want or v["board"].split("/")[-1] == want]
            how = "release-manifest.json: board directory"
        if len(hits) > 1:
            fail(3, "board %r has %d builds in %s, pick one with --board: %s"
                 % (want, len(hits), tag, ", ".join(v["name"] for v in hits)))
        if hits:
            a = stems.get(hits[0]["full_name"])
            if a is None:
                fail(3, "manifest lists %s but the release has no asset for %s"
                     % (hits[0]["name"], hits[0]["full_name"]))
            chosen = (hits[0]["name"], a)
    if chosen is None:
        # No manifest (older releases) or not listed in it: go by asset names alone.
        how = "asset name"
        if want in stems:
            chosen = (want, stems[want])
        else:
            hits = [s for s in stems if s.endswith("-" + want)]
            if len(hits) == 1:
                chosen = (want, stems[hits[0]])
            elif len(hits) > 1:
                fail(3, "several assets end in -%s: %s" % (want, ", ".join(sorted(hits))))
    if chosen is None:
        near = sorted(s for s in stems if want in s or s in want)
        if not near:
            words = [w for w in re.split(r"[-_.]", want) if len(w) > 2]
            near = sorted(s for s in stems if any(w in s for w in words))[:15]
        fail(3, "no firmware for board %r in release %s.%s\n  list everything with: --list"
             % (want, tag, ("\n  similar: " + ", ".join(near)) if near else ""))
    name, a = chosen
    if not SAFE_NAME.match(name):
        fail(3, "variant name %r is not a safe directory name" % clean(name))
    sys.stderr.write("fetch_prebuilt: matched %s via %s -> %s\n" % (want, how, a["name"]))
    print("\t".join([name, a["name"], a["url"], str(a["size"]), a["digest"]]))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def cmd_verify(args):
    actual_size = os.path.getsize(args.file)
    actual = sha256_file(args.file)
    ok = True
    notes = []
    if args.size is not None and args.size >= 0:
        if actual_size == args.size:
            notes.append("size matches the GitHub API (%d bytes)" % actual_size)
        else:
            ok = False
            notes.append("SIZE MISMATCH: file %d bytes, GitHub API says %d" % (actual_size, args.size))
    if args.digest and args.digest != "-":
        want = args.digest.split(":", 1)[1]
        if want == actual:
            notes.append("sha256 matches the GitHub API digest")
        else:
            ok = False
            notes.append("SHA256 MISMATCH vs GitHub API digest (%s)" % want)
    else:
        notes.append("GitHub API gave no digest for this asset")
    if args.sums and os.path.isfile(args.sums):
        listed = None
        with open(args.sums, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"^([0-9a-f]{64})[ \t]+\*?(\S+)\s*$", line)
                if m and m.group(2) == args.name:
                    listed = m.group(1)
        if listed is None:
            notes.append("not listed in the release's SHA256SUMS")
        elif listed == actual:
            notes.append("sha256 matches the release's SHA256SUMS")
        else:
            ok = False
            notes.append("SHA256 MISMATCH vs SHA256SUMS (%s)" % listed)
    print("  sha256:  %s  %s" % (actual, args.name))
    for n in notes:
        print("  check:   %s" % n)
    if not ok:
        sys.exit(4)


def cmd_unpack(args):
    dest = os.path.realpath(args.dest)
    if not os.path.isdir(dest):
        fail(2, "destination %s is not a directory" % dest)
    if os.listdir(dest):
        fail(2, "destination %s is not empty" % dest)
    try:
        zf = zipfile.ZipFile(args.zip)
    except (OSError, zipfile.BadZipFile) as e:
        fail(4, "not a readable ZIP: %s" % e)
    with zf:
        infos = zf.infolist()
        if len(infos) > MAX_ZIP_MEMBERS:
            fail(4, "ZIP has %d members (limit %d) - refusing" % (len(infos), MAX_ZIP_MEMBERS))
        total = 0
        plan = []
        seen = set()
        for info in infos:
            name = info.filename
            if name.endswith("/"):
                continue                                   # directory entry
            parts = name.split("/")
            if (name.startswith("/") or "\\" in name or ":" in name
                    or any(p in ("", ".", "..") or not SAFE_NAME.match(p) for p in parts)):
                fail(4, "ZIP member with unsafe name %r - refusing" % clean(name))
            mode = (info.external_attr >> 16) & 0xFFFF
            if mode and not stat.S_ISREG(mode):
                fail(4, "ZIP member %s is not a regular file (mode %o) - refusing" % (name, mode))
            if info.flag_bits & 0x1:
                fail(4, "ZIP member %s is encrypted - refusing" % name)
            if info.file_size > MAX_MEMBER_BYTES:
                fail(4, "ZIP member %s claims %d bytes (limit %d) - refusing" % (name, info.file_size, MAX_MEMBER_BYTES))
            if name.lower() in seen:
                fail(4, "ZIP has two members named %s - refusing" % name)
            seen.add(name.lower())
            total += info.file_size
            plan.append((info, parts))
        if total > MAX_TOTAL_BYTES:
            fail(4, "ZIP would unpack to %d bytes (limit %d) - refusing" % (total, MAX_TOTAL_BYTES))
        if not plan:
            fail(4, "ZIP contains no files")
        for info, parts in plan:
            target = os.path.join(dest, *parts)
            if os.path.commonpath([dest, os.path.realpath(os.path.dirname(target))]) != dest:
                fail(4, "ZIP member %s would land outside %s" % (info.filename, dest))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            written = 0
            try:
                with zf.open(info) as src, open(target, "xb") as out:
                    while True:
                        block = src.read(1 << 20)
                        if not block:
                            break
                        written += len(block)
                        if written > MAX_MEMBER_BYTES:      # do not trust the declared size
                            fail(4, "ZIP member %s expands past %d bytes - refusing" % (info.filename, MAX_MEMBER_BYTES))
                        out.write(block)
            except (zipfile.BadZipFile, OSError, EOFError, ValueError) as e:   # includes CRC errors
                fail(4, "cannot extract %s: %s" % (info.filename, e))
            os.chmod(target, 0o444)                         # reference data: read-only, never executable
            print("  unpacked: %s (%d bytes, zip crc ok)" % ("/".join(parts), written))


def cmd_check_unpacked(args):
    """Are the files in DIR still byte-identical to the members of ZIP?"""
    root = os.path.realpath(args.dir)
    try:
        zf = zipfile.ZipFile(args.zip)
    except (OSError, zipfile.BadZipFile) as e:
        fail(4, "not a readable ZIP: %s" % e)
    bad = 0
    with zf:
        for info in zf.infolist()[:MAX_ZIP_MEMBERS]:
            name = info.filename
            parts = name.split("/")
            if name.endswith("/") or any(p in ("", ".", "..") or not SAFE_NAME.match(p) for p in parts):
                continue
            target = os.path.join(root, *parts)
            if os.path.islink(target) or not os.path.isfile(target):
                print("  check:   %s is MISSING from the directory" % name)
                bad += 1
                continue
            h = hashlib.sha256()
            total = 0
            try:
                with zf.open(info) as src:
                    for block in iter(lambda: src.read(1 << 20), b""):
                        total += len(block)
                        if total > MAX_MEMBER_BYTES:
                            fail(4, "ZIP member %s expands past the size limit" % name)
                        h.update(block)
            except (zipfile.BadZipFile, OSError, EOFError, ValueError) as e:
                fail(4, "cannot read %s from the ZIP: %s" % (name, e))
            if h.hexdigest() == sha256_file(target):
                print("  check:   %s is identical to the copy inside the ZIP" % name)
            else:
                print("  check:   %s DIFFERS from the copy inside the ZIP" % name)
                bad += 1
    if bad:
        sys.exit(4)


def first_bytes_hint(path):
    try:
        with open(path, "rb") as f:
            head = f.read(16)
    except OSError:
        return ""
    if head[:1] == b"\xe9" and len(head) >= 16:
        chip = head[12] | (head[13] << 8)
        return "ESP image header (magic 0xE9, chip id 0x%04x) - a bootloader / merged binary" % chip
    if head[:4] == b"PK\x03\x04":
        return "ZIP archive"
    if head[:1] in (b"{", b"["):
        return "JSON text"
    return ""


def cmd_describe(args):
    root = os.path.realpath(args.dir)
    rows = []
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for fn in sorted(files):
            p = os.path.join(base, fn)
            if os.path.islink(p) or not os.path.isfile(p):
                rows.append(("(not a regular file)", 0, os.path.relpath(p, root), ""))
                continue
            rows.append((sha256_file(p), os.path.getsize(p), os.path.relpath(p, root), first_bytes_hint(p)))
    for digest, size, rel, hint in rows:
        print("  %s  %10d  %s" % (digest, size, clean(rel)))
        if hint:
            print("  %s  %10s  `- %s" % (" " * 64, "", hint))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("release-info"); p.add_argument("release"); p.set_defaults(fn=cmd_release_info)
    p = sub.add_parser("support"); p.add_argument("release"); p.set_defaults(fn=cmd_support)
    p = sub.add_parser("list"); p.add_argument("release"); p.add_argument("--manifest"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("select"); p.add_argument("release"); p.add_argument("board")
    p.add_argument("--manifest"); p.set_defaults(fn=cmd_select)
    p = sub.add_parser("verify"); p.add_argument("file"); p.add_argument("--name", required=True)
    p.add_argument("--size", type=int); p.add_argument("--digest"); p.add_argument("--sums")
    p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("unpack"); p.add_argument("zip"); p.add_argument("dest"); p.set_defaults(fn=cmd_unpack)
    p = sub.add_parser("check-unpacked"); p.add_argument("zip"); p.add_argument("dir")
    p.set_defaults(fn=cmd_check_unpacked)
    p = sub.add_parser("describe"); p.add_argument("dir"); p.set_defaults(fn=cmd_describe)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
