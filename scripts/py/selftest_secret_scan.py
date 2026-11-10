#!/usr/bin/env python3
"""selftest_secret_scan.py — prove scripts/py/secret_scan.py blocks leaks and never prints a secret.

    python3 -I -B selftest_secret_scan.py          (run by: scripts/90-check-secrets.sh --selftest)

Uses the synthetic flash image of selftest_flash_tools.py (fake WiFi/MQTT/websocket secrets, a
board UUID and a WiFi PMK blob in NVS) as the only dump in a temporary backups/ directory, stages
files into a temporary git repository and checks the scanner's verdict on each:
    leaks that must be caught    plain value, value in a log line, upper-cased UUID, blob as hex
    paths that must be refused   a file under backups/, a flash image over 64 KiB
    must stay clean              ordinary text, a secret embedded inside a longer identifier
and that no planted value appears in the scanner's output (also with --explain).
Nothing outside the temporary directory is touched.

Exit status: 0 every check passed; 1 at least one failed.
"""

import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import selftest_flash_tools as T  # noqa: E402

FAILS = []


def check(cond: bool, what: str) -> None:
    print("  %s  %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAILS.append(what)


def main() -> int:
    S = T.SECRETS
    with tempfile.TemporaryDirectory() as tmp:
        backups = os.path.join(tmp, "backups")
        os.makedirs(os.path.join(backups, "aabbccddeeff"))
        with open(os.path.join(backups, "aabbccddeeff", "fake-full-4MB.bin"), "wb") as f:
            f.write(bytes(T.build_flash()))
        repo = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(repo, "backups"))

        def git(*args):
            return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)

        def scan(*args, backups_dir=backups):
            r = subprocess.run([sys.executable, "-I", "-B", os.path.join(HERE, "secret_scan.py"),
                                "--repo", repo, "--backups", backups_dir, *args],
                               capture_output=True, text=True)
            return r.returncode, r.stdout + r.stderr

        files = {
            "clean.md": "nothing secret here\n",
            "leak-wifi.txt": "wifi: %s\n" % S["wifi password"],
            "leak-uuid.log": "I (213) Board: UUID=%s SKU=x\n" % S["board uuid"],
            "leak-uuid-upper.txt": "id %s\n" % S["board uuid"].upper(),
            "leak-pmk.txt": "pmk %s\n" % T.PMK.hex(),
            "embedded.txt": "zz%szz\n" % S["board uuid"],
            "backups/notes.txt": "anything\n",
        }
        for name, text in files.items():
            with open(os.path.join(repo, name), "w") as f:
                f.write(text)
        with open(os.path.join(repo, "big.bin"), "wb") as f:
            f.write(b"\xff" * (70 * 1024))
        git("init", "-q")
        git("add", "-A")

        print("staged files, fake dump present:")
        rc, out = scan("--staged")
        check(rc == 1, "exit status 1 when something leaks (got %d)" % rc)
        for name, label in (("leak-wifi.txt", "password"), ("leak-uuid.log", "uuid"),
                            ("leak-uuid-upper.txt", "uuid"), ("leak-pmk.txt", "pmk")):
            line = next((l for l in out.splitlines() if l.startswith("LEAK      %s:" % name)), "")
            check(bool(line) and label in line.lower(), "%s reported as a %s leak" % (name, label))
        check("FORBIDDEN backups/notes.txt" in out, "a file under backups/ is refused")
        check("FORBIDDEN big.bin" in out, "a 70 KiB *.bin is refused")
        check("clean.md" not in out, "ordinary text is not reported")
        check("embedded.txt" not in out, "a secret inside a longer identifier is not reported")
        planted = [v for v in S.values() if len(v) >= 6] + [T.PMK.hex()]
        check(not [v for v in planted if v in out or v.upper() in out], "no planted value in the output")

        rc, out = scan("--staged", "--explain")
        check("<NVS " in out, "--explain masks the value in the shown line")
        check(not [v for v in planted if v in out or v.upper() in out], "no planted value in --explain output")

        print("leaky files removed from the index:")
        git("rm", "-q", "--cached", "leak-wifi.txt", "leak-uuid.log", "leak-uuid-upper.txt",
            "leak-pmk.txt", "backups/notes.txt", "big.bin")
        rc, out = scan("--staged")
        check(rc == 0 and "result    CLEAN" in out, "clean index passes (exit %d)" % rc)
        rc, out = scan("--tracked")
        check(rc == 0, "--tracked on the clean index passes (exit %d)" % rc)

        print("no dumps available:")
        empty = os.path.join(tmp, "no-backups")
        os.makedirs(empty)
        rc, out = scan("--staged", backups_dir=empty)
        check(rc == 0 and "WARN      no dumps" in out, "warns that only path rules applied (exit %d)" % rc)

    print("selftest %s: %d failure(s)" % ("passed" if not FAILS else "FAILED", len(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
