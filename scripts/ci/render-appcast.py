#!/usr/bin/env python3
"""Render the Sparkle appcast for one release (LVX-57).

The feed holds one item: the release it ships with. It is an asset of that
release, and the app reads it through /releases/latest/download/appcast.xml,
so the newest stable release is always the only candidate and an older
appcast never has to be edited. Deltas from the last few releases ride in the
same item; a copy older than those downloads the full zip.

Every value comes from the caller (build-update-feed.sh), which signs the
archives with sign_update. Nothing here touches the network or a key, so the
Linux CI tests it (test-render-appcast.sh).

usage: render-appcast.py --tag vX.Y.Z --build N --minimum-system 15.0
           --pub-date 'RFC 822 date' --zip LENGTH:SIGNATURE
           [--delta FROM_BUILD:LENGTH:SIGNATURE ...] [--repo owner/name]
"""

import argparse
import re
import sys
from xml.sax.saxutils import quoteattr, escape

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIGNATURE = re.compile(r"^[A-Za-z0-9+/]{86}==$")  # base64 of a 64-byte ed25519 signature


def fail(message):
    print(f"render-appcast.py: {message}", file=sys.stderr)
    sys.exit(2)


def parse_archive(value, with_build):
    parts = value.split(":")
    if len(parts) != (3 if with_build else 2):
        fail(f"malformed archive argument: {value!r}")
    *head, length, signature = parts
    if not length.isdigit() or int(length) == 0:
        fail(f"length is not a positive integer: {length!r}")
    if not SIGNATURE.match(signature):
        fail(f"not an EdDSA signature: {signature!r}")
    if with_build and not head[0].isdigit():
        fail(f"delta base is not a build number: {head[0]!r}")
    return (head[0] if with_build else None), int(length), signature


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--minimum-system", required=True)
    parser.add_argument("--pub-date", required=True)
    parser.add_argument("--zip", required=True)
    parser.add_argument("--delta", action="append", default=[])
    parser.add_argument("--repo", default="T0mSIlver/localvoxtral")
    args = parser.parse_args()

    if not re.match(r"^v\d+\.\d+\.\d+$", args.tag):
        fail(f"only a stable vX.Y.Z release gets a feed: {args.tag!r}")
    if not args.build.isdigit():
        fail(f"build is not a number: {args.build!r}")
    if not re.match(r"^\d+(\.\d+){1,2}$", args.minimum_system):
        fail(f"minimum system is not a macOS version: {args.minimum_system!r}")

    version = args.tag[1:]
    base = f"https://github.com/{args.repo}/releases/download/{args.tag}"
    _, zip_length, zip_signature = parse_archive(args.zip, with_build=False)
    deltas = [parse_archive(d, with_build=True) for d in args.delta]
    seen = set()
    for from_build, _, _ in deltas:
        if from_build in seen:
            fail(f"two deltas from build {from_build}")
        if int(from_build) >= int(args.build):
            fail(f"delta from build {from_build} is not older than {args.build}")
        seen.add(from_build)

    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">',
        "  <channel>",
        "    <title>localvoxtral</title>",
        "    <item>",
        f"      <title>{escape(version)}</title>",
        f"      <pubDate>{escape(args.pub_date)}</pubDate>",
        f"      <sparkle:version>{args.build}</sparkle:version>",
        f"      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{args.minimum_system}</sparkle:minimumSystemVersion>",
        f"      <sparkle:fullReleaseNotesLink>https://github.com/{args.repo}/releases/tag/{args.tag}</sparkle:fullReleaseNotesLink>",
        "      <enclosure"
        f" url={quoteattr(f'{base}/localvoxtral-{args.tag}.zip')}"
        f" length=\"{zip_length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(zip_signature)}/>",
    ]
    if deltas:
        lines.append("      <sparkle:deltas>")
        for from_build, length, signature in sorted(deltas, key=lambda d: -int(d[0])):
            lines.append(
                "        <enclosure"
                f" url={quoteattr(f'{base}/localvoxtral-{args.tag}-from-{from_build}.delta')}"
                f" sparkle:deltaFrom=\"{from_build}\" length=\"{length}\""
                " type=\"application/octet-stream\""
                f" sparkle:edSignature={quoteattr(signature)}/>"
            )
        lines.append("      </sparkle:deltas>")
    lines += ["    </item>", "  </channel>", "</rss>"]
    print("\n".join(lines))


if __name__ == "__main__":
    main()
