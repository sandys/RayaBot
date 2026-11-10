#!/usr/bin/env python3
"""check_skills.py — the engine of `scripts/91-agent-skills.sh check`.

    python3 -I -B check_skills.py REPO_ROOT

Checks the agent setup that .agents/REPO_GUIDE.md describes and prints one line per finding.

Skills (.agents/skills/<name>/SKILL.md)
  - frontmatter holds only name + description, on single lines
  - name = folder name, [a-z0-9] words joined by single hyphens, 1-64 chars
  - description 1-1024 chars; no angle brackets (Claude Code shows them as entities); no ": " or
    " #" (they break strict YAML parsers unless quoted)
  - the four sections: Context & Purpose, Step-by-Step Workflow, Decision Points & Branching
    Logic, Quality Criteria & Completion Checks
  - SKILL.md under 500 lines; no README/CHANGELOG inside the skill folder
  - every relative markdown link resolves inside the skill folder
  - every scripts/, docs/, config/ or patches/ file it names exists in the repo
    (names with an all-caps placeholder part, like NAME.sdkconfig or NN-verb.sh, are skipped)
  - the skill is listed in .agents/REPO_GUIDE.md
Links
  - .claude/skills/<name> and .gemini/skills/<name>: relative symlinks resolving to
    .agents/skills/<name>, one per skill and nothing else (Gemini CLI 0.27.3 reads only
    .gemini/skills; newer versions also read .agents/skills and let it win, so the links are harmless)
  - no SKILL.md copies anywhere else in the tracked part of the repo
  - AGENTS.md, CLAUDE.md, GEMINI.md: symlinks that resolve to .agents/REPO_GUIDE.md and can be read
    (no loop); the guide itself is a regular file

Exit status: 0 no problems; 1 problems found.
"""

import os
import re
import sys

SECTIONS = ["## Context & Purpose", "## Step-by-Step Workflow",
            "## Decision Points & Branching Logic", "## Quality Criteria & Completion Checks"]
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
LINK_RE = re.compile(r"\]\(([^)\s]+)\)")
PATH_RE = re.compile(r"`((?:scripts|docs|config|patches)/[A-Za-z0-9_./-]+\.(?:sh|py|md|sdkconfig|patch|txt|ps1))")
PLACEHOLDER_RE = re.compile(r"(^|[/._-])[A-Z]{2,}([/._-]|$)")
GUIDE = ".agents/REPO_GUIDE.md"
ROOT_LINKS = ["AGENTS.md", "CLAUDE.md", "GEMINI.md"]
SKIP_DIRS = {".git", "firmware", "cache", "out", "prebuilt", "tools", "logs", "backups", "state", "node_modules"}

PROBLEMS = []


def ok(msg: str) -> None:
    print("ok       " + msg)


def bad(msg: str) -> None:
    PROBLEMS.append(msg)
    print("PROBLEM  " + msg)


def frontmatter(text: str):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fields, odd = {}, []
            for line in lines[1:i]:
                m = re.match(r"^([A-Za-z0-9_-]+):\s?(.*)$", line)
                if m:
                    fields[m.group(1)] = m.group(2).strip()
                elif line.strip():
                    odd.append(line)
            return fields, odd
    return None, None


def check_skill(root: str, skills_dir: str, name: str, guide_text: str) -> None:
    sdir = os.path.join(skills_dir, name)
    path = os.path.join(sdir, "SKILL.md")
    if not os.path.isfile(path):
        bad("%s: no SKILL.md" % name)
        return
    text = open(path, encoding="utf-8").read()
    fields, odd = frontmatter(text)
    if fields is None:
        bad("%s: SKILL.md does not start with a --- frontmatter block" % name)
        return
    if odd:
        bad("%s: frontmatter has multi-line or unparsed lines; keep each field on one line" % name)
    extra = sorted(set(fields) - {"name", "description"})
    if extra:
        bad("%s: frontmatter fields beyond name/description: %s (not portable)" % (name, ", ".join(extra)))
    nm = fields.get("name", "").strip("'\"")
    if nm != name:
        bad("%s: frontmatter name '%s' differs from the folder name" % (name, nm))
    if not NAME_RE.match(name) or len(name) > 64:
        bad("%s: name must be lowercase words joined by single hyphens, at most 64 chars" % name)
    desc = fields.get("description", "")
    quoted = len(desc) >= 2 and desc[0] == desc[-1] and desc[0] in "'\""
    body_desc = desc[1:-1] if quoted else desc
    if not body_desc:
        bad("%s: empty description" % name)
    if len(body_desc) > 1024:
        bad("%s: description is %d chars (limit 1024)" % (name, len(body_desc)))
    if "<" in body_desc or ">" in body_desc:
        bad("%s: description contains angle brackets" % name)
    if not quoted and (": " in body_desc or " #" in body_desc):
        bad("%s: unquoted description contains ': ' or ' #' (breaks strict YAML)" % name)
    missing = [s for s in SECTIONS if not re.search(r"^%s\s*$" % re.escape(s), text, re.M)]
    if missing:
        bad("%s: missing section(s): %s" % (name, "; ".join(missing)))
    nlines = text.count("\n") + 1
    if nlines > 500:
        bad("%s: SKILL.md has %d lines (keep it under 500; move detail to references/)" % (name, nlines))
    for entry in os.listdir(sdir):
        if entry.upper().startswith(("README", "CHANGELOG")):
            bad("%s: %s inside a skill folder (noise for agents)" % (name, entry))
    for target in LINK_RE.findall(text):
        if re.match(r"^[a-z]+:", target) or target.startswith("#"):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(sdir, target.split("#")[0]))):
            bad("%s: link target missing: %s" % (name, target))
    for rel in sorted(set(PATH_RE.findall(text))):
        if PLACEHOLDER_RE.search(rel):
            continue
        if not os.path.exists(os.path.join(root, rel)):
            bad("%s: names %s, which does not exist" % (name, rel))
    if ("`%s`" % name) not in guide_text:
        bad("%s: not listed in %s" % (name, GUIDE))
    ok("skill %-30s %3d lines, description %4d chars" % (name, nlines, len(body_desc)))


def check_tool_links(root: str, tool: str, names) -> None:
    rel = "%s/skills" % tool
    tdir = os.path.join(root, tool, "skills")
    if not os.path.isdir(tdir):
        bad("%s is missing (run: scripts/91-agent-skills.sh link)" % rel)
        return
    if os.path.islink(tdir):
        bad("%s is itself a symlink; use one link per skill" % rel)
    entries = set(os.listdir(tdir))
    for name in sorted(names):
        link = os.path.join(tdir, name)
        want = os.path.realpath(os.path.join(root, ".agents", "skills", name))
        if name not in entries:
            bad("%s/%s missing (run: scripts/91-agent-skills.sh link)" % (rel, name))
        elif not os.path.islink(link):
            bad("%s/%s is a real directory, i.e. a copy" % (rel, name))
        elif os.path.isabs(os.readlink(link)):
            bad("%s/%s uses an absolute target; use ../../.agents/skills/%s" % (rel, name, name))
        elif os.path.realpath(link) != want:
            bad("%s/%s points to %s" % (rel, name, os.readlink(link)))
        else:
            ok("%s/%s -> %s" % (rel, name, os.readlink(link)))
    for extra in sorted(entries - set(names)):
        bad("%s/%s has no canonical skill in .agents/skills" % (rel, extra))


def check_no_copies(root: str) -> None:
    canon = os.path.realpath(os.path.join(root, ".agents", "skills"))
    for d, subdirs, files in os.walk(root):
        subdirs[:] = [s for s in subdirs if s not in SKIP_DIRS]
        if "SKILL.md" in files and not os.path.realpath(d).startswith(canon + os.sep):
            bad("SKILL.md copy outside .agents/skills: %s" % os.path.relpath(os.path.join(d, "SKILL.md"), root))


def check_root_links(root: str) -> None:
    guide = os.path.join(root, GUIDE)
    if not os.path.isfile(guide) or os.path.islink(guide):
        bad("%s must be a regular file (it is the one real copy)" % GUIDE)
        return
    want = os.path.realpath(guide)
    for name in ROOT_LINKS:
        p = os.path.join(root, name)
        if not os.path.lexists(p):
            bad("%s missing (run: scripts/91-agent-skills.sh link)" % name)
        elif not os.path.islink(p):
            bad("%s is a regular file, i.e. a copy of the guide" % name)
        elif os.path.realpath(p) != want:
            bad("%s resolves to %s, not %s" % (name, os.path.realpath(p), GUIDE))
        else:
            try:
                with open(p, encoding="utf-8") as f:
                    f.readline()
                ok("%s -> %s (readable, no loop)" % (name, os.readlink(p)))
            except OSError as e:
                bad("%s cannot be read (%s)" % (name, e.strerror))


def main() -> int:
    root = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else ".")
    skills_dir = os.path.join(root, ".agents", "skills")
    if not os.path.isdir(skills_dir):
        bad(".agents/skills does not exist")
        return 1
    names = sorted(e for e in os.listdir(skills_dir) if os.path.isdir(os.path.join(skills_dir, e)))
    guide_text = open(os.path.join(root, GUIDE), encoding="utf-8").read() if os.path.isfile(os.path.join(root, GUIDE)) else ""
    for name in names:
        check_skill(root, skills_dir, name, guide_text)
    for tool in (".claude", ".gemini"):
        check_tool_links(root, tool, names)
    check_no_copies(root)
    check_root_links(root)
    print("result   %s: %d skill(s), %d problem(s)" % ("OK" if not PROBLEMS else "PROBLEMS", len(names), len(PROBLEMS)))
    return 1 if PROBLEMS else 0


if __name__ == "__main__":
    sys.exit(main())
