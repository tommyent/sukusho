#!/usr/bin/env python3
"""Compile and run the multi-source fractional-cut export & preview redaction pixel check."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
build = derived / "VideoSequenceExportCheck"
build.mkdir(exist_ok=True)

sources = sorted(str(p) for p in (repo / "Screendrop").rglob("*.swift") if p.name != "AppEntry.swift")
sources.append(str(repo / "scripts/check-video-sequence-export.swift"))
source_list = build / "sources"
source_list.write_text("\n".join(sources))
binary = build / "check-video-sequence-export"

command = [
    "xcrun", "swiftc", "-parse-as-library",
    "-module-name", "Screendrop", "-target", "arm64-apple-macos26.0",
    "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-D", "DEBUG",
    "-I", str(products),
    "-F", str(products),
    "-framework", "Sparkle",
    "-Xlinker", "-rpath", "-Xlinker", str(products),
    str(products / "DockProgress.o"),
    "@" + str(source_list),
    "-o", str(binary),
]
with (build / "compile.log").open("w") as log:
    if subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT).returncode:
        sys.exit(f"Harness compile failed: {build / 'compile.log'}")

library = products / "Sukusho Dev.app/Contents/Resources/default.metallib"
if library.exists():
    shutil.copyfile(library, build / "default.metallib")

subprocess.run([str(binary)], cwd=repo, check=True)
