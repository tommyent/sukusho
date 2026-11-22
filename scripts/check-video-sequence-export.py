#!/usr/bin/env python3
"""Compile and run the windowless video-sequence export, redaction, and format-guard checks.

Links against the already-built Debug Dev objects when present (falling back to
compiling sources otherwise), and always executes inside an isolated temporary
HOME / CFFIXED_USER_HOME / TMPDIR so the user's real defaults, Library, and
Application Support are never touched.
"""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
arch = platform.machine()
objects_dir = derived / f"Build/Intermediates.noindex/Screendrop.build/Debug Dev/Screendrop.build/Objects-normal/{arch}"
sparkle_dir = derived / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
framework_dir = products if (products / "Sparkle.framework").exists() else sparkle_dir
build = derived / "VideoSequenceExportCheck"
build.mkdir(parents=True, exist_ok=True)
binary = build / "check-video-sequence-export"
check_source = repo / "scripts/check-video-sequence-export.swift"

common_flags = [
    "xcrun", "swiftc", "-parse-as-library",
    "-target", f"{arch}-apple-macos26.0",
    "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
    "-D", "DEBUG",
    "-I", str(products),
    "-F", str(framework_dir),
    "-framework", "Sparkle",
    "-Xlinker", "-rpath", "-Xlinker", str(framework_dir),
    str(products / "DockProgress.o"),
]

swiftmodule = objects_dir / "Screendrop.swiftmodule"
app_objects = sorted(
    str(p) for p in objects_dir.glob("*.o")
    if p.name != "AppEntry.o"
) if objects_dir.exists() else []

if swiftmodule.exists() and app_objects:
    command = common_flags + [
        "-module-name", "CheckVideoSequenceExport",
        "-D", "HARNESS_LINKED_MODULE",
        "-I", str(objects_dir),
        str(check_source),
        *app_objects,
        "-o", str(binary),
    ]
    mode = f"linked Dev objects ({len(app_objects)} .o files)"
else:
    sources = sorted(
        str(p) for p in (repo / "Screendrop").rglob("*.swift")
        if p.name != "AppEntry.swift"
    )
    sources.append(str(check_source))
    source_list = build / "sources"
    source_list.write_text("\n".join(sources))
    command = common_flags + [
        "-module-name", "Screendrop",
        "@" + str(source_list),
        "-o", str(binary),
    ]
    mode = f"compiled sources ({len(sources)} .swift files)"

print(f"Building harness via {mode}...")
with (build / "compile.log").open("w") as log:
    if subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT).returncode:
        sys.exit(f"Harness compile failed ({mode}): {build / 'compile.log'}")

library = products / "Sukusho Dev.app/Contents/Resources/default.metallib"
if library.exists():
    shutil.copyfile(library, build / "default.metallib")

with tempfile.TemporaryDirectory(prefix="screendrop-video-seq-", dir="/private/tmp") as root:
    tmp_dir = Path(root) / "tmp"
    tmp_dir.mkdir()
    env = dict(
        os.environ,
        HOME=root,
        CFFIXED_USER_HOME=root,
        TMPDIR=str(tmp_dir),
    )
    subprocess.run([str(binary)], cwd=repo, env=env, check=True)
