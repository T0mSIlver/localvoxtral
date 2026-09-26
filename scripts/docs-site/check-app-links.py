#!/usr/bin/env python3
"""Fail when a docs page or anchor the app links to is missing from the site.

Usage: scripts/docs-site/check-app-links.py <site-dir>

Reads every DocsLink.page("...") call under Sources/ and looks for the page's
index.html, and the anchor's id, in the built site. Also fails on a Settings
link that still points at a Markdown file on github.com.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CALL = re.compile(r'DocsLink\.page\("([^"]*)"\)')
RAW_DOC = re.compile(r"github\.com/T0mSIlver/localvoxtral/blob/main/\S+\.md")


def main(site: Path) -> int:
    failures, checked = [], 0
    for swift in sorted((REPO / "Sources").rglob("*.swift")):
        text = swift.read_text()
        where = swift.relative_to(REPO)
        for m in RAW_DOC.finditer(text):
            failures.append(f"{where}: links a Markdown file, use DocsLink.page: {m[0]}")
        for m in CALL.finditer(text):
            checked += 1
            path, _, anchor = m[1].partition("#")
            page = site / path / "index.html"
            if not path.endswith("/") and path:
                failures.append(f"{where}: {m[1]}: page path must end in /")
            elif not page.is_file():
                failures.append(f"{where}: {m[1]}: no page at {path}")
            elif anchor and f'id="{anchor}"' not in page.read_text():
                failures.append(f"{where}: {m[1]}: {path} has no anchor #{anchor}")
    for f in failures:
        print(f"FAIL {f}")
    if checked == 0:
        print("FAIL found no DocsLink.page calls under Sources/")
        return 1
    print(f"{checked} app docs links checked, {len(failures)} broken")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-app-links.py <site-dir>")
    sys.exit(main(Path(sys.argv[1])))
