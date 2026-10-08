#!/usr/bin/env python3
"""Seed the README demo's History with twelve weeks of made-up dictations.

usage: seed-demo-history.py <history.store> <project dir>...

The demo's History and Insights beat needs weeks of use behind it, and the
take itself makes six dictations. record-demo.sh lets the app create its
store in the demo's own data folder (LOCALVOXTRAL_DATA_HOME, never the
owner's), quits it, runs this, and launches it again.

The store is SwiftData's Core Data SQLite file. Rows go straight into its
one entity table, with Z_MAX raised to match, the way Core Data would have
written them. Every column this script does not know stays NULL, as for a
record an older build wrote. The texts name the staged repos' identifiers:
early weeks spell them as speech recognition hears them, later weeks as
written, so Insights' learning trend climbs.
"""

import os
import random
import sqlite3
import sys
import time
import uuid

CORE_DATA_EPOCH = 978307200  # 2001-01-01 in Unix time
WEEKS = 12
TABLE = "ZDICTATIONSESSIONRECORD"

# (heard early, written later) pairs and the prompts that use them.
PROMPTS = {
    "payments": [
        ("Mock the {t} client in the refund tests.", "pay lane", "Paylane"),
        ("Why does {t} retry three times before it gives up?", "pay lane", "Paylane"),
        ("Run the refund tests under {t} with coverage.", "v test", "Vitest"),
        ("Log the {t} request id with every failed charge.", "pay lane", "Paylane"),
        ("Add a {t} test for a zero amount refund.", "v test", "Vitest"),
    ],
    "docs": [
        ("Move the guides to the new {t} sidebar.", "docu saurus", "Docusaurus"),
        ("Show the {t} sign in flow in the quick start.", "act me", "Acme"),
        ("Link the {t} docs from the payments guide.", "pay lane", "Paylane"),
        ("Bump {t} and rebuild the docs site.", "docu saurus", "Docusaurus"),
    ],
}


def column_names(db):
    return {row[1] for row in db.execute(f"PRAGMA table_info({TABLE})")}


def template(db):
    """Provider and model names from a real row, if the app wrote one."""
    row = db.execute(
        f"SELECT ZPROVIDER, ZMODEL, ZPOLISHBACKEND, ZPOLISHMODEL FROM {TABLE} ORDER BY Z_PK LIMIT 1"
    ).fetchone()
    if row and row[0]:
        return row
    return ("realtime_api", "Voxtral-Mini-4B-Realtime", "bundledHelper", "Qwen3.5-4B")


def rows(projects, now, rng):
    for week in range(WEEKS):
        # 0 = oldest week. Use grows, and so does the share spelled right.
        learned = week / (WEEKS - 1)
        per_week = 8 + week * 3
        for _ in range(per_week):
            name = rng.choice(list(projects))
            sentence, heard, written = rng.choice(PROMPTS.get(name, PROMPTS["payments"]))
            raw = sentence.format(t=written if rng.random() < 0.15 + 0.8 * learned else heard)
            polished = sentence.format(t=written)
            day = (WEEKS - 1 - week) * 7 + rng.randint(0, 6)
            started = now - day * 86400 - rng.randint(9 * 3600, 19 * 3600)
            speaking = max(2.5, len(raw.split()) / 2.6 + rng.uniform(-0.5, 1.5))
            overlay = rng.random() < 0.6
            polish = rng.uniform(0.6, 1.4) if overlay else None
            yield {
                "ZID": uuid.uuid4().bytes,
                "ZSTARTEDAT": started - CORE_DATA_EPOCH,
                "ZSTOPPEDAT": started + speaking - CORE_DATA_EPOCH if overlay else None,
                "ZFINISHEDAT": started + speaking + (polish or 0.3) - CORE_DATA_EPOCH,
                "ZRAWTEXT": raw,
                "ZPOLISHEDTEXT": polished if overlay else None,
                "ZPOLISHINGDURATIONSECONDS": polish,
                "ZPOLISHPROFILE": "agent" if overlay else None,
                "ZOUTPUTMODE": "overlay_buffer" if overlay else "live_auto_paste",
                "ZTARGETAPPBUNDLEID": "com.mitchellh.ghostty",
                "ZSTATUS": "completed" if overlay else "stt_completed",
                "ZCOMMITSUCCEEDED": 1,
                "ZPROJECTKEY": projects[name],
                "ZPROJECTNAME": name,
                "ZJOINEDAGENT": "claude",
                "ZEDITOUTCOME": "edited" if overlay and rng.random() < 0.35 - 0.25 * learned else ("clean" if overlay else None),
            }


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    store, dirs = argv[1], argv[2:]
    if not os.path.isfile(store):
        sys.exit(f"no History store at {store}: launch the app on this data folder first")
    projects = {os.path.basename(d.rstrip("/")): os.path.realpath(d) for d in dirs}
    db = sqlite3.connect(store)
    with db:
        entity, last = db.execute(
            "SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'DictationSessionRecord'"
        ).fetchone()
        provider, model, polish_backend, polish_model = template(db)
        known = column_names(db)
        count = 0
        for record in rows(projects, time.time(), random.Random(1847)):
            last += 1
            count += 1
            record.update({
                "Z_PK": last, "Z_ENT": entity, "Z_OPT": 1,
                "ZPROVIDER": provider, "ZMODEL": model,
                "ZPOLISHBACKEND": polish_backend if record["ZPOLISHEDTEXT"] else None,
                "ZPOLISHMODEL": polish_model if record["ZPOLISHEDTEXT"] else None,
            })
            record = {k: v for k, v in record.items() if k in known}
            columns = ", ".join(record)
            marks = ", ".join("?" for _ in record)
            db.execute(f"INSERT INTO {TABLE} ({columns}) VALUES ({marks})", list(record.values()))
        db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?", (last, entity))
    db.close()
    print(f"Seeded {count} dictations over {WEEKS} weeks into {store}")


if __name__ == "__main__":
    main(sys.argv)
