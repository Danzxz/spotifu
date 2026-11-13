#!/usr/bin/env python3
"""Install only the Spotifu extension, without changing Spotify's theme."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
local = root / ".local"
tools = local / "spicetify"
binary = tools / "spicetify"
if not binary.is_file():
    raise SystemExit("Download the official Spicetify Darwin release into .local/spicetify first")
application = Path("/Applications/Spotify.app")
backup = local / "backups/Spotify-before-Spotifu.app"
if not backup.exists():
    backup.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ditto", str(application), str(backup)], check=True)
configuration = local / "spicetify-config"
(configuration / "Extensions").mkdir(parents=True, exist_ok=True)
token_file = local / "resolver-token"
if not token_file.exists():
    token_file.write_text(secrets.token_urlsafe(32))
    token_file.chmod(0o600)
token = token_file.read_text().strip()
extension = "window.SPOTIFU_CONFIG=" + json.dumps({"endpoint": "http://127.0.0.1:8765", "token": token}) + ";\n"
extension += (root / "desktop/spotifu.js").read_text()
(configuration / "Extensions/spotifu.js").write_text(extension)
environment = dict(os.environ, SPICETIFY_CONFIG=str(configuration), SPICETIFY_STATE=str(local / "spicetify-state"))
for arguments in [
    ["config", "spotify_path", str(application / "Contents/Resources"), "prefs_path", str(Path.home() / "Library/Application Support/Spotify/prefs")],
    ["config", "current_theme", "", "inject_css", "0", "replace_colors", "0", "overwrite_assets", "0", "inject_theme_js", "0"],
    ["config", "extensions", "spotifu.js"],
    ["backup", "apply", "--no-restart"],
]:
    subprocess.run([str(binary), *arguments], env=environment, check=True)
print("Native Spotify extension installed. Original application backup:", backup)
