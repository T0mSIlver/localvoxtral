#!/usr/bin/env python3
"""Copy the published docs pages into a folder Zensical can build.

Usage: scripts/docs-site/stage.py <out-dir>

Writes <out-dir>/zensical.toml and the pages under <out-dir>/pages.

Zensical has no exclude_docs yet (zensical/zensical#135), so the site builds
from a copy holding only the public pages, at their repo paths. In the copy:

- a link to a file the site doesn't publish (AGENTS.md, docs/agent/, source
  files) points at github.com instead;
- an image a page shows is copied along with it;
- a GitHub alert (> [!NOTE]) becomes an admonition, which Zensical renders;
- a bare user-attachments video URL, which GitHub turns into a player,
  becomes a <video> element.

The Markdown in the repo stays as GitHub renders it.
"""

import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GITHUB = "https://github.com/T0mSIlver/localvoxtral"
PUBLISHED_GLOBS = [
    "README.md",
    "docs/*.md",
    "docs/release-notes/*.md",
    "integrations/*/README.md",
]
# The theme's logo and favicon (zensical.toml).
THEME_ASSETS = {Path("assets/icons/app/AppIcon.png")}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}

MD_LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
REF_LINK = re.compile(r"^(\s*\[[^\]]+\]:\s+)(\S+)", re.M)
HTML_ATTR = re.compile(r"""((?:src|href)=")([^"]+)(")""")
SRCSET = re.compile(r"""(srcset=")([^"\s,]+)(")""")
ALERT = re.compile(r"^> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*\n((?:>.*\n?)*)", re.M)
VIDEO = re.compile(r"^(https://github\.com/user-attachments/assets/[0-9a-f-]+)\s*$", re.M)
ALERT_KIND = {
    "NOTE": "note",
    "TIP": "tip",
    "IMPORTANT": 'info "Important"',
    "WARNING": "warning",
    "CAUTION": "danger",
}


def published_pages() -> set[Path]:
    return {p.relative_to(REPO) for g in PUBLISHED_GLOBS for p in REPO.glob(g)}


def rewrite_target(target: str, page: Path, pages: set[Path], assets: set[Path]) -> str:
    if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith(("#", "/")):
        return target
    path, _, anchor = target.partition("#")
    resolved = (REPO / page.parent / path).resolve()
    try:
        rel = resolved.relative_to(REPO)
    except ValueError:
        return target
    if rel in pages or not resolved.exists():
        return target
    if resolved.is_file() and resolved.suffix.lower() in IMAGE_SUFFIXES:
        assets.add(rel)
        return target
    kind = "tree" if resolved.is_dir() else "blob"
    return f"{GITHUB}/{kind}/main/{rel.as_posix()}" + (f"#{anchor}" if anchor else "")


def climb_relative(target: str, climb: str) -> str:
    if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith(("#", "/")):
        return target
    return climb + target


def convert_alerts(text: str) -> str:
    def repl(m: re.Match) -> str:
        body = [re.sub(r"^> ?", "", line) for line in m.group(2).splitlines()]
        indented = "\n".join(("    " + line) if line.strip() else "" for line in body)
        return f"!!! {ALERT_KIND[m.group(1)]}\n\n{indented}\n"

    return ALERT.sub(repl, text)


def stage(out: Path) -> None:
    pages = published_pages()
    assets = set(THEME_ASSETS)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copy2(Path(__file__).with_name("zensical.toml"), out / "zensical.toml")
    out = out / "pages"
    for page in sorted(pages):
        text = (REPO / page).read_text()
        text = MD_LINK.sub(lambda m: m[1] + rewrite_target(m[2], page, pages, assets) + m[3], text)
        text = REF_LINK.sub(lambda m: m[1] + rewrite_target(m[2], page, pages, assets), text)
        text = HTML_ATTR.sub(lambda m: m[1] + rewrite_target(m[2], page, pages, assets) + m[3], text)
        # Zensical rebases src and href for a page served at docs/x/ but not
        # srcset, so a srcset on a page that isn't a README climbs one more level.
        climb = "" if page.name == "README.md" else "../"
        text = SRCSET.sub(lambda m: m[1] + climb_relative(rewrite_target(m[2], page, pages, assets), climb) + m[3], text)
        text = convert_alerts(text)
        text = VIDEO.sub(r'<video src="\1" controls muted playsinline preload="metadata" style="width: 100%"></video>', text)
        dest = out / page
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
    for asset in sorted(assets):
        dest = out / asset
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / asset, dest)
    print(f"staged {len(pages)} pages and {len(assets)} assets into {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: stage.py <out-dir>")
    stage(Path(sys.argv[1]).resolve())
