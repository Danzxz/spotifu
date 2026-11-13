#!/usr/bin/env python3
"""Use the exact same offline engine in the app and the Eevee tweak."""
from pathlib import Path
import shutil
root = Path(__file__).resolve().parents[1]
destination = root / "ios/EeveeSpotify/Sources/EeveeSpotify/SpotifuShared"
destination.mkdir(exist_ok=True)
for folder in ("Core", "UI"):
    for source in (root / "Shared" / folder).glob("*.swift"):
        shutil.copy2(source, destination / source.name)
