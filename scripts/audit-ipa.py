#!/usr/bin/env python3
"""Static package audit, not a signature or on-device acceptance test."""
import json
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
with zipfile.ZipFile(ipa) as archive:
    names = set(archive.namelist())
    info = plistlib.loads(archive.read("Payload/Spotify.app/Info.plist"))
    missing = []
    local = ipa.resolve().parent / ".audit"
    local.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=local) as temporary:
        for member in ("Frameworks/EeveeSpotify.dylib", "Frameworks/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf"):
            path = Path(temporary) / Path(member).name
            path.write_bytes(archive.read("Payload/Spotify.app/" + member))
            lines = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[2:]
            for line in lines:
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith("@rpath/"):
                    relative = dependency.removeprefix("@rpath/")
                    if not any("Payload/Spotify.app/" + prefix + relative in names for prefix in ("Frameworks/", "")):
                        missing.append(dependency)
                elif dependency.startswith("/var/jb/"):
                    missing.append(dependency)
    if missing:
        raise SystemExit("Unresolved non-system dependencies: " + repr(missing))
    print(json.dumps({"bundleIdentifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"], "buildVersion": info["CFBundleVersion"], "minOSVersion": info["MinimumOSVersion"], "size": ipa.stat().st_size, "dependenciesResolved": True}))
