#!/usr/bin/env python3
import os
from pathlib import Path
import runpy
import secrets
import sys
root = Path(__file__).resolve().parents[1]
local = root / ".local"
local.mkdir(exist_ok=True)
token_file = local / "resolver-token"
if not token_file.exists():
    token_file.write_text(secrets.token_urlsafe(32))
    token_file.chmod(0o600)
os.environ["SPOTIFU_TOKEN"] = token_file.read_text().strip()
sys.path.insert(0, str(root / "server"))
runpy.run_path(str(root / "server/app.py"), run_name="__main__")
