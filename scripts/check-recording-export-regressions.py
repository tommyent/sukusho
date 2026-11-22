#!/usr/bin/env python3
"""Compile the offline recording checks against app sources; never launch the app."""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
build = derived / "RecordingExportChecks"
build.mkdir(exist_ok=True)
bench = Path("/private/tmp/screendrop-team/bench.lock")
if bench.exists():
    sys.exit("Another benchmark owns bench.lock; wait before running.")
sources = sorted(str(p) for p in (repo / "Screendrop").rglob("*.swift") if p.name != "AppEntry.swift")
sources.append(str(repo / "scripts/check-recording-export-regressions.swift"))
source_list = build / "sources"
source_list.write_text("\n".join(sources))
binary = build / "check-recording-export-regressions"
command = [
    "lockf", "/private/tmp/screendrop-team/build.lock", "xcrun", "swiftc", "-parse-as-library",
    "-module-name", "Screendrop", "-target", f"{platform.machine()}-apple-macos27.0",
    "-default-isolation", "MainActor", "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-D", "DEBUG",
    "-I", str(products), "-F", str(sparkle), "-framework", "Sparkle",
    "-Xlinker", "-rpath", "-Xlinker", str(sparkle),
    str(products / "DockProgress.o"), "@" + str(source_list), "-o", str(binary),
]
with (build / "compile.log").open("w") as log:
    if subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT).returncode:
        sys.exit(f"Harness compile failed: {build / 'compile.log'}")
with tempfile.TemporaryDirectory(prefix="screendrop-recording-checks-", dir="/private/tmp") as root:
    temporary = Path(root) / "tmp"
    temporary.mkdir()
    environment = dict(os.environ, HOME=root, CFFIXED_USER_HOME=root, TMPDIR=str(temporary))
    subprocess.run([str(binary)], env=environment, check=True, timeout=120)
