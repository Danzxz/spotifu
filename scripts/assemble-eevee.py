#!/usr/bin/env python3
"""Replace existing Eevee components; never inject an arbitrary vanilla IPA."""
import plistlib
import sys
import tempfile
import zipfile
import shutil
from pathlib import Path

base, package, output = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    with zipfile.ZipFile(base) as archive:
        for member in archive.infolist():
            destination = (root / member.filename).resolve()
            if not destination.is_relative_to(root.resolve()):
                raise ValueError("Unsafe archive path")
        archive.extractall(root)
    app = root / "Payload/Spotify.app"
    target = app / "Frameworks/EeveeSpotify.dylib"
    if not target.is_file():
        raise SystemExit("Base must already contain loaded EeveeSpotify.dylib")
    replacements = [(next(package.rglob("EeveeSpotify.dylib")), target),
                    (next(package.rglob("EeveeSpotify.bundle")), app / "EeveeSpotify.bundle"),
                    (next(package.rglob("EeveeSwiftProtobuf.framework")), app / "Frameworks/EeveeSwiftProtobuf.framework")]
    for source, destination in replacements:
        if destination.is_dir(): shutil.rmtree(destination)
        elif destination.exists(): destination.unlink()
        if source.is_dir(): shutil.copytree(source, destination)
        else: shutil.copy2(source, destination)
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleShortVersionString"] = "9.1.88"
    info["UIFileSharingEnabled"] = True
    info["LSSupportsOpeningDocumentsInPlace"] = True
    info["UIBackgroundModes"] = list(set(info.get("UIBackgroundModes", [])) | {"audio"})
    info_path.write_bytes(plistlib.dumps(info))
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in root.rglob("*"):
            if file.is_file(): archive.write(file, file.relative_to(root))
