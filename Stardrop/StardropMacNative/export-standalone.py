#!/usr/bin/env python3
"""Export native Starfruit source into a new folder without touching Git history."""
import argparse
import shutil
from pathlib import Path


def export(destination: Path) -> None:
    native = Path(__file__).resolve().parent
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise SystemExit(f"Refusing to overwrite existing destination: {destination}")
    destination.mkdir(parents=True)
    for folder in ("Sources", "Resources", "Tests"):
        source = native / folder
        if source.is_dir():
            shutil.copytree(source, destination / folder,
                            ignore=shutil.ignore_patterns(".DS_Store", "__pycache__", "*.o"))
    for name in ("build-native.sh", "generate-appcast.sh", "sparkle-public-key.txt", "appcast.xml", "README.md"):
        source = native / name
        if source.is_file():
            shutil.copy2(source, destination / name)
    icon = native.parent / "Assets" / "Starfruit_Mac.icns"
    if icon.exists():
        (destination / "Resources").mkdir(exist_ok=True)
        shutil.copy2(icon, destination / "Resources" / "Starfruit.icns")
    license_file = native.parent.parent / "LICENSE"
    shutil.copy2(license_file, destination / "LICENSE")
    shutil.copy2(license_file, destination / "Resources" / "LICENSE")
    (destination / ".gitignore").write_text(
        ".DS_Store\n.deps/\nStarfruit.app/\n*.o\n.build/\n", encoding="utf-8")
    (destination / "UPSTREAM.md").write_text(
        "# Provenance\n\nStarfruit derives from Floogen/Stardrop and retains its GPLv3 license.\n"
        "Upstream development was integrated through 9c5e145bf55af07cd735cfadbc65c5aa5309fef4.\n"
        "Original history remains in https://github.com/Bunnygamezsc/Starfruit.\n"
        "This source export contains the native macOS app and its required resources.\n",
        encoding="utf-8")
    print(f"Standalone native source exported to {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    export(parser.parse_args().destination)
