#!/usr/bin/env python3
"""Prints what became of Settings' term suggestions, week by week (LVX-11).

Run on the Mac whose app made the suggestions. It reads the counts the app
keeps in its defaults (`settings.term_suggestion_outcomes`): per week and
per source (learned terms, model runs), chips shown, accepted and refused.
Counts only: the record holds no term, so the output is safe to paste.

    scripts/term-suggestion-outcomes.py [--domain com.localvoxtral.app]
"""
import argparse
import datetime
import json
import plistlib
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--domain", default="com.localvoxtral.app")
    args = parser.parse_args()
    exported = subprocess.run(
        ["/usr/bin/defaults", "export", args.domain, "-"], capture_output=True, check=True
    ).stdout
    blob = plistlib.loads(exported).get("settings.term_suggestion_outcomes")
    if blob is None:
        print("no suggestion outcomes recorded yet")
        return 0
    weeks = json.loads(blob)["weeks"]
    print("week        source   shown  accepted  refused  accept share")
    for week in weeks:
        # Swift's JSONEncoder writes a Date as seconds since 2001-01-01.
        start = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(
            seconds=week["start"]
        )
        for source in ("learned", "model"):
            counts = week[source]
            decided = counts["accepted"] + counts["refused"]
            share = f"{100 * counts['accepted'] / decided:.0f}%" if decided else "-"
            print(
                f"{start:%Y-%m-%d}  {source:7}  {counts['shown']:5}  {counts['accepted']:8}"
                f"  {counts['refused']:7}  {share:>12}"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
