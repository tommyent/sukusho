#!/usr/bin/env python3
"""Plain-words Library search against the real on-device model, without UI.

Pass a scratch folder. Compiles the app's Spotlight and plain-search sources
with the check into a windowless app bundle with its own bundle ID (Core
Spotlight keeps one index per bundle ID, so the app's index and the Library
are never touched), runs it and prints good / OK / bad counts.
"""
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

repo = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]).resolve()
contents = build / "CapturePlainSearchCheck.app/Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump({
        "CFBundleIdentifier": "com.tommyent.Sukusho.search-check",
        "CFBundleExecutable": "check",
        "CFBundleName": "CapturePlainSearchCheck",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }, file)
sources = [str(repo / "Screendrop" / name) for name in (
    "CaptureSpotlight.swift", "CaptureSpotlightBackend.swift", "CapturePlainSearch.swift",
    "CaptureLibraryText.swift", "CaptureSource.swift",
)] + [str(repo / "scripts/check-capture-plain-search.swift")]
binary = contents / "MacOS/check"
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-module-name", "Screendrop",
    "-target", f"{platform.machine()}-apple-macos27.0", "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
    *sources, "-o", str(binary),
], cwd=repo, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(contents.parent)], check=True)
subprocess.run([str(binary)], check=True)
