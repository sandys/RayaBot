#!/usr/bin/env python3
"""selftest_check_skills.py — prove scripts/py/check_skills.py accepts a correct setup and catches
each kind of breakage.

    python3 -I -B selftest_check_skills.py        (run by: scripts/91-agent-skills.sh selftest)

Builds a minimal correct layout in a temporary directory (guide + root links, one skill, per-skill
links for .claude and .gemini, a script the skill names), checks it passes, then applies one defect
at a time to a fresh copy and checks the checker exits 1 with the expected message. Nothing outside
the temporary directory is touched.

Exit status: 0 every case behaved; 1 otherwise.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SKILL = """---
name: good-skill
description: Do one thing in this repo. Use when testing the checker.
---

# Good skill

## Context & Purpose
Text.

## Step-by-Step Workflow
1. Run `scripts/10-real.sh`. Fill in `config/NAME.sdkconfig`. See [assets/t.md](assets/t.md).

## Decision Points & Branching Logic
- Text.

## Quality Criteria & Completion Checks
- Text.
"""
FAILS = []


def build(root: str) -> None:
    os.makedirs(os.path.join(root, ".agents", "skills", "good-skill", "assets"))
    os.makedirs(os.path.join(root, "scripts"))
    with open(os.path.join(root, ".agents", "REPO_GUIDE.md"), "w") as f:
        f.write("# Guide\n\n| task | `good-skill` |\n")
    with open(os.path.join(root, ".agents", "skills", "good-skill", "SKILL.md"), "w") as f:
        f.write(SKILL)
    open(os.path.join(root, ".agents", "skills", "good-skill", "assets", "t.md"), "w").close()
    open(os.path.join(root, "scripts", "10-real.sh"), "w").close()
    for tool in (".claude", ".gemini"):
        os.makedirs(os.path.join(root, tool, "skills"))
        os.symlink("../../.agents/skills/good-skill", os.path.join(root, tool, "skills", "good-skill"))
    for name in ("AGENTS.md", "CLAUDE.md", "GEMINI.md"):
        os.symlink(".agents/REPO_GUIDE.md", os.path.join(root, name))


def edit_skill(old: str, new: str):
    def apply(root):
        p = os.path.join(root, ".agents", "skills", "good-skill", "SKILL.md")
        text = open(p).read()
        assert old in text, old
        open(p, "w").write(text.replace(old, new))
    return apply


def replace_link_with_copy(root):
    link = os.path.join(root, ".claude", "skills", "good-skill")
    os.remove(link)
    shutil.copytree(os.path.join(root, ".agents", "skills", "good-skill"), link)


def claude_md_regular(root):
    os.remove(os.path.join(root, "CLAUDE.md"))
    shutil.copy(os.path.join(root, ".agents", "REPO_GUIDE.md"), os.path.join(root, "CLAUDE.md"))


def loop(root):
    for a, b in (("CLAUDE.md", "AGENTS.md"), ("AGENTS.md", "CLAUDE.md")):
        os.remove(os.path.join(root, a))
        os.symlink(b, os.path.join(root, a))


def drop_gemini_link(root):
    os.remove(os.path.join(root, ".gemini", "skills", "good-skill"))


def absolute_link(root):
    link = os.path.join(root, ".gemini", "skills", "good-skill")
    os.remove(link)
    os.symlink(os.path.join(root, ".agents", "skills", "good-skill"), link)


def unlist(root):
    open(os.path.join(root, ".agents", "REPO_GUIDE.md"), "w").write("# Guide\n")


def readme_inside(root):
    open(os.path.join(root, ".agents", "skills", "good-skill", "README.md"), "w").close()


def stray_copy(root):
    os.makedirs(os.path.join(root, "docs", "old"))
    shutil.copy(os.path.join(root, ".agents", "skills", "good-skill", "SKILL.md"), os.path.join(root, "docs", "old"))


CASES = [
    ("name differs from folder", edit_skill("name: good-skill", "name: other-skill"), "differs from the folder name"),
    ("missing section", edit_skill("## Decision Points & Branching Logic\n", ""), "missing section"),
    ("unquoted ': ' in description", edit_skill("Do one thing", "Do: one thing"), "breaks strict YAML"),
    ("extra frontmatter field", edit_skill("---\n\n#", "allowed-tools: Read\n---\n\n#"), "beyond name/description"),
    ("angle brackets in description", edit_skill("Do one thing", "Do <one> thing"), "angle brackets"),
    ("names a missing script", edit_skill("scripts/10-real.sh", "scripts/99-gone.sh"), "does not exist"),
    ("broken relative link", edit_skill("(assets/t.md)", "(assets/missing.md)"), "link target missing"),
    ("skill copied instead of linked", replace_link_with_copy, "is a real directory, i.e. a copy"),
    ("CLAUDE.md is a regular file", claude_md_regular, "is a regular file"),
    ("CLAUDE.md <-> AGENTS.md loop", loop, "CLAUDE.md"),
    ("missing .gemini link", drop_gemini_link, ".gemini/skills/good-skill missing"),
    ("absolute link target", absolute_link, "absolute target"),
    ("skill not listed in guide", unlist, "not listed in"),
    ("README inside skill", readme_inside, "inside a skill folder"),
    ("SKILL.md copy elsewhere", stray_copy, "copy outside .agents/skills"),
]


def run(root: str):
    r = subprocess.run([sys.executable, "-I", "-B", os.path.join(HERE, "check_skills.py"), root],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base")
        build(base)
        rc, out = run(base)
        ok = rc == 0 and "result   OK" in out
        print("  %s  correct layout passes (exit %d)" % ("ok  " if ok else "FAIL", rc))
        if not ok:
            FAILS.append("baseline")
            print(out)
        for i, (what, apply, expect) in enumerate(CASES):
            root = os.path.join(tmp, "case%02d" % i)
            shutil.copytree(base, root, symlinks=True)
            apply(root)
            rc, out = run(root)
            ok = rc == 1 and any(expect in l for l in out.splitlines() if l.startswith("PROBLEM"))
            print("  %s  %s -> exit %d, PROBLEM mentions %r" % ("ok  " if ok else "FAIL", what, rc, expect))
            if not ok:
                FAILS.append(what)
                print("\n".join("        " + l for l in out.splitlines() if l.startswith(("PROBLEM", "result"))))
    print("selftest %s: %d failure(s)" % ("passed" if not FAILS else "FAILED", len(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
