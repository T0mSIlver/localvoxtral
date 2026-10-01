#!/usr/bin/env python3
"""Launch smoke for a packaged localvoxtral.app (ci.yml, release.yml).

Starts the app's binary with CFFIXED_USER_HOME set to SMOKE_HOME, checks that
it is still running after 2 s, then stops it. The runner runs as the owner, so
the app must resolve Application Support under that throwaway home: a copy
that opened the owner's history store could migrate it to its own schema, and
its launch sweep deletes recordings (#985). The history store appearing under
SMOKE_HOME proves the redirect held.

Env: SMOKE_APP (the .app), SMOKE_HOME (an existing, empty directory).
"""
import os
import subprocess
import sys
import time

app_binary = os.path.join(os.environ["SMOKE_APP"], "Contents/MacOS/localvoxtral")
home = os.environ["SMOKE_HOME"]
store = os.path.join(home, "Library/Application Support/localvoxtral/history.store")

process = subprocess.Popen([app_binary], env={**os.environ, "CFFIXED_USER_HOME": home})
time.sleep(2)
exit_code = process.poll()
if exit_code is not None:
    sys.exit(f"packaged app exited during smoke test: {exit_code}")

# The store opens during launch; a slow runner gets a few more seconds.
deadline = time.monotonic() + 10
while not os.path.exists(store) and time.monotonic() < deadline and process.poll() is None:
    time.sleep(0.25)
store_opened = os.path.exists(store)

process.terminate()
try:
    process.wait(timeout=5)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait(timeout=5)

if not store_opened:
    sys.exit(f"the app did not open its history store under the smoke home: {store} is missing")
print(f"launch smoke: history store opened under the smoke home ({store})")
