#!/usr/bin/env python3
"""Fail when something people read links a docs page as Markdown.

Usage: scripts/docs-site/check-human-links.py [--repo DIR] [--site SITE_DIR]

People read the docs on the site; agents read the Markdown. So a surface
listed in SURFACES that links a published page (stage.py's PUBLISHED_GLOBS)
by repo path, or by a github.com URL, fails. With --site, every site URL in
those surfaces must also name a built page, and an anchor on it.

Not checked, because agents read them: AGENTS.md files, docs/agent/, code
comments, CI files. Links between published pages stay relative too:
stage.py makes them site links.
"""

import argparse
import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("stage", HERE / "stage.py")
stage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stage)

# The human-facing surfaces, and who reads them.
SURFACES = {
    "README.md": "the GitHub landing page",
    "CONTRIBUTING.md": "contributors, on GitHub",
    "integrations/*/README.md": "plugin users who open the integration on GitHub",
    "integrations/**/*.json": "plugin manifests and marketplace text",
    "docs/release-notes/*.md": "GitHub release bodies, where a relative link breaks",
    ".github/pull_request_template.md": "PR authors",
    ".github/ISSUE_TEMPLATE/*": "issue authors",
    "scripts/release.sh": "release text it writes",
    "Sources/**/*.swift": "strings the app and its CLI show: Learn more links, alerts, doctor output",
}
# Files whose comments are for agents; only their string literals count.
CODE_SUFFIXES = {".swift", ".json", ".sh"}

GITHUB_DOC = re.compile(re.escape(stage.GITHUB) + r"/(?:blob|tree|raw)/[^/\s]+/([^\s)\"'#>]+)")
SITE_URL = re.compile(re.escape(stage.SITE) + r"([^\s)\"'<>`]*)")
PATH_TOKEN = re.compile(r"(?<![\w/.-])((?:\.\.?/)*[\w./-]+\.md)\b")
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')
COMMENT = re.compile(r"^\s*(?://|#|\*|/\*)")


def surface_files(repo: Path) -> list[Path]:
    found = {p for g in SURFACES for p in repo.glob(g) if p.is_file()}
    return sorted(found)


def code_strings(text: str) -> str:
    return "\n".join(m[0] for line in text.splitlines() if not COMMENT.match(line) for m in STRING.finditer(line))


def link_targets(text: str) -> list[str]:
    targets = [m[2] for m in stage.MD_LINK.finditer(text)]
    targets += [m[2] for m in stage.REF_LINK.finditer(text)]
    targets += [m[2] for m in stage.HTML_ATTR.finditer(text)]
    return targets


def check(repo: Path, site: Path | None) -> int:
    pages = stage.published_pages(repo)
    names = {p.as_posix() for p in pages}
    failures, site_links = [], 0
    for f in surface_files(repo):
        where = f.relative_to(repo)
        text = f.read_text()
        if f.suffix in CODE_SUFFIXES:
            text = code_strings(text)
            for m in PATH_TOKEN.finditer(text):
                token = re.sub(r"^(?:\.\.?/)+", "", m[1])
                if "/" in token and token in names:
                    failures.append(f"{where}: names {m[1]}; link {stage.SITE}… instead")
        else:
            for target in link_targets(text):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith(("#", "/")):
                    continue
                path = target.partition("#")[0]
                resolved = (f.parent / path).resolve()
                if resolved.is_relative_to(repo) and resolved.relative_to(repo) in pages:
                    failures.append(f"{where}: links {target}; link {stage.SITE}… instead")
        for m in GITHUB_DOC.finditer(text):
            if m[1] in names:
                failures.append(f"{where}: links {m[0]}; link {stage.SITE}… instead")
        if site is None:
            continue
        for m in SITE_URL.finditer(text):
            site_links += 1
            path, _, anchor = m[1].rstrip(".,;:").partition("#")
            page = site / path / "index.html"
            if path and not path.endswith("/"):
                failures.append(f"{where}: {m[0]}: page path must end in /")
            elif not page.is_file():
                failures.append(f"{where}: {m[0]}: no page at {path or '/'}")
            elif anchor and f'id="{anchor}"' not in page.read_text():
                failures.append(f"{where}: {m[0]}: {path or '/'} has no anchor #{anchor}")
    for line in failures:
        print(f"FAIL {line}")
    summary = f"{len(surface_files(repo))} human-facing files checked"
    if site is not None:
        summary += f", {site_links} site links resolved against {site}"
    print(f"{summary}, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, default=stage.REPO)
    ap.add_argument("--site", type=Path)
    args = ap.parse_args()
    sys.exit(check(args.repo.resolve(), args.site.resolve() if args.site else None))
