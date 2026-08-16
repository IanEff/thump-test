#!/usr/bin/env python3
"""Sync thump's S3-compatible WAL/transcript credentials (storage.tf's
outputs) into thump's .env file, so its Tiltfile's thump-s3-secret
local_resource always has current values without a manual
tofu-output/copy-paste round trip.

This bucket (and its HMAC key) is ordinary Tofu state living in this same
repo, same disposable posture as everything else here -- `task destroy` +
`task apply` recreates it with a new random suffix and a new key every
time. Re-run this after every fresh apply, not just the first one.

Usage:
    python3 sync_thump_env.py    (requires: tofu output values below;
                                  THUMP_ENV_PATH env var to override the
                                  default sibling-repo path)
"""

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

THUMP_ENV_PATH = Path(os.environ.get(
    "THUMP_ENV_PATH", str(Path.home() / "projects" / "go" / "thump" / ".env"),
))

# .env key -> the Tofu output name it's sourced from (outputs.tf).
OUTPUTS = {
    "S3_ENDPOINT": "thump_s3_endpoint",
    "S3_BUCKET": "thump_s3_bucket",
    "S3_ACCESS_KEY": "thump_s3_access_key",
    "S3_SECRET_KEY": "thump_s3_secret_key",
}


def tofu_output(name: str) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", name],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"tofu output -raw {name} failed: {result.stderr.strip()}", file=sys.stderr)
        print("Run this from the repo root after `tofu apply`.", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def backup_file(path: Path) -> None:
    if path.exists():
        backup_path = path.with_suffix(f".bak.{int(time.time())}")
        shutil.copy2(path, backup_path)
        print(f"Backed up {path.name} to {backup_path.name}")


def upsert(content: str, key: str, value: str) -> str:
    """Replace an existing `KEY="..."` line in place, or append one --
    every other line (comments, ANTHROPIC_API_KEY, ...) passes through
    untouched."""
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
    line = f'{key}="{value}"'
    if pattern.search(content):
        return pattern.sub(line, content)
    sep = "" if content == "" or content.endswith("\n") else "\n"
    return content + sep + line + "\n"


def main() -> None:
    if not THUMP_ENV_PATH.exists():
        print(f"{THUMP_ENV_PATH} doesn't exist -- create it first "
              "(see thump's Tiltfile, thump-anthropic-secret's comment).", file=sys.stderr)
        sys.exit(1)

    values = {key: tofu_output(output_name) for key, output_name in OUTPUTS.items()}

    backup_file(THUMP_ENV_PATH)
    content = THUMP_ENV_PATH.read_text(encoding="utf-8")
    for key, value in values.items():
        content = upsert(content, key, value)
    THUMP_ENV_PATH.write_text(content, encoding="utf-8")

    print(f"Updated {THUMP_ENV_PATH}:")
    for key in OUTPUTS:
        shown = values[key] if key != "S3_SECRET_KEY" else "*" * 8
        print(f"  {key}={shown}")


if __name__ == "__main__":
    main()
