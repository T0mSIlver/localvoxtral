#!/usr/bin/env python3
"""Rewrite the em dashes out of an embedded Sparkle.framework's strings.

Sparkle's update window puts an em dash between "localvoxtral 0.18.0 is now
available" and "you have 0.17.0". The app's copy uses none (owner's ruling on
LVX-57), so package_app.sh runs this on the copy it embeds, before signing.

English (Base) gets a new sentence: "is now available. You have 0.17.0."
Every other language gets a comma, which reads as an aside in each of them.
Fails if an em dash survives or a string loses a format specifier.

usage: sparkle-strings-without-em-dash.py <Sparkle.framework>
"""
import glob
import os
import plistlib
import re
import sys

DASH = re.compile(r"\s*—\s*")
SPEC = re.compile(r"%(?:\d+\$)?@")


def rewrite(value: str, base: bool) -> str:
    if base:
        return DASH.sub(lambda m: ". ", value).replace(". you ", ". You ")
    return DASH.sub(", ", value)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    framework = sys.argv[1]
    # Versions/Current links to Versions/B: one entry per real file.
    files = sorted({os.path.realpath(p) for p in glob.glob(
        os.path.join(framework, "Versions", "*", "Resources", "*.lproj", "Sparkle.strings"))})
    if not files:
        print(f"no Sparkle.strings under {framework}", file=sys.stderr)
        return 1
    changed = 0
    for path in files:
        with open(path, "rb") as f:
            raw = f.read()
        fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
        strings = plistlib.loads(raw)
        base = os.path.basename(os.path.dirname(path)) == "Base.lproj"
        dirty = False
        for key, value in strings.items():
            if "—" not in value:
                continue
            new = rewrite(value, base)
            if "—" in new or SPEC.findall(new) != SPEC.findall(value):
                print(f"{path}: could not rewrite {value!r}", file=sys.stderr)
                return 1
            strings[key] = new
            dirty = True
            changed += 1
        if dirty:
            with open(path, "wb") as f:
                plistlib.dump(strings, f, fmt=fmt)
    print(f"Sparkle strings: {changed} em dash string(s) rewritten in {len(files)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
