#!/usr/bin/env python3
"""Generate a SideStore source from the final IPA; never invent permissions."""
import argparse
import datetime
import hashlib
import json
import plistlib
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path


def generate(ipa, url, notes, icon, read_entitlements=None):
    ipa = Path(ipa)
    if not url.startswith("https://"):
        raise ValueError("Release URL must use HTTPS")
    def signed_permissions(binary):
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(binary)], capture_output=True)
        raw = result.stdout
        if result.returncode or not raw:
            raise ValueError("Could not extract signed entitlements for " + binary.name)
        return plistlib.loads(raw)
    read_entitlements = read_entitlements or signed_permissions
    permissions, privacy = set(), {}
    with zipfile.ZipFile(ipa) as archive, tempfile.TemporaryDirectory(dir=ipa.resolve().parent) as temporary:
        infos = [n for n in archive.namelist() if n.startswith("Payload/") and n.endswith("/Info.plist") and (n.count("/") == 2 or ".appex/Info.plist" in n)]
        main = next(n for n in infos if n.count("/") == 2)
        info = plistlib.loads(archive.read(main))
        if info["CFBundleIdentifier"] != "com.spotify.client":
            raise ValueError("Unexpected bundle identifier; existing SideStore updates would break")
        for name in infos:
            bundle = plistlib.loads(archive.read(name))
            for key, value in bundle.items():
                if "UsageDescription" in key and isinstance(value, str): privacy[key] = value
            executable = name.rsplit("/", 1)[0] + "/" + bundle["CFBundleExecutable"]
            binary = Path(temporary) / (str(len(permissions)) + "-" + Path(executable).name)
            binary.write_bytes(archive.read(executable))
            permissions.update(read_entitlements(binary).keys())
    version = {"version": info["CFBundleShortVersionString"], "buildVersion": str(info["CFBundleVersion"]), "date": datetime.datetime.now(datetime.timezone.utc).isoformat(), "localizedDescription": notes, "downloadURL": url, "size": ipa.stat().st_size, "minOSVersion": info["MinimumOSVersion"], "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()}
    app = {"name": "Spotifu · Spotify Beta", "bundleIdentifier": info["CFBundleIdentifier"], "developerName": "Danzxz / EeveeSpotify contributors", "localizedDescription": notes, "iconURL": icon, "versions": [version], "appPermissions": {"entitlements": sorted(permissions), "privacy": privacy}}
    return {"name": "Spotifu", "identifier": "com.danzxz.spotifu.source", "sourceURL": "https://raw.githubusercontent.com/Danzxz/spotifu/main/source/spotifu.json", "apps": [app], "news": []}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("url")
    parser.add_argument("--notes", required=True)
    parser.add_argument("--icon", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check-url", action="store_true")
    args = parser.parse_args()
    source = generate(args.ipa, args.url, args.notes, args.icon)
    if args.check_url:
        with urllib.request.urlopen(urllib.request.Request(args.url, method="HEAD"), timeout=30) as response:
            size = response.headers.get("Content-Length")
            if size and int(size) != args.ipa.stat().st_size: raise SystemExit("Release asset size mismatch")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
