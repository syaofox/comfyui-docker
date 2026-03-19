#!/usr/bin/env python3
import json
import subprocess
import glob
import os

snapshot_files = sorted(
    glob.glob("/workspace/user/__manager/snapshots/*.json"),
    key=os.path.getmtime,
    reverse=True,
)
if not snapshot_files:
    exit(0)

snapshot = snapshot_files[0]
with open(snapshot) as f:
    data = json.load(f)

if "pips" not in data:
    exit(0)

for pkg, extra in data["pips"].items():
    cmd = [
        "/workspace/venv/bin/pip",
        "install",
        "--no-cache-dir",
        extra if extra else pkg,
    ]
    subprocess.run(cmd)
