#!/usr/bin/env python3
"""Read `localvoxtral ... --json` answers for scripts/record-demo.sh.

usage: demo-cli-json.py capture-ids          # stdin: capture list --json; one id per line
       demo-cli-json.py terms                # stdin: terms list --json; one term per line
       demo-cli-json.py filed-url            # stdin: capture show --json; the issue URL, if filed
       demo-cli-json.py last-raw             # stdin: history last --json; its words as dictated

The walk finds the objects by their fields rather than by the envelope
around them, so it reads both the bare payload and the full response.
"""

import json
import sys


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if argv[1] == "capture-ids":
        for node in walk(data):
            if "id" in node and "capturedAt" in node:
                print(node["id"])
    elif argv[1] == "terms":
        for node in walk(data):
            if "term" in node and "state" in node:
                print(node["term"])
    elif argv[1] == "filed-url":
        for node in walk(data):
            if node.get("filedURL"):
                print(node["filedURL"])
                return
    elif argv[1] == "last-raw":
        for node in walk(data):
            if "rawText" in node:
                print(node["rawText"])
                return
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
