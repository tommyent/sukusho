#!/usr/bin/env python3
"""Under heavy, from the repo root: <Release DerivedData> <build|run> <binary folder> [arguments].

Build at each revision before timing; each run gets fresh History and CLI defaults.
"""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

dd, action, folder = Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]).resolve()
root = Path(__file__).resolve().parents[1]
binary = folder / "SukushoOptimizerBenchmark"
if action == "build":
    folder.mkdir(exist_ok=True, parents=True)
    helpers = folder / "Contents/Helpers"
    helpers.parent.mkdir(exist_ok=True)
    if not helpers.exists():
        helpers.symlink_to(root / "Vendor/optimizers", target_is_directory=True)
    products = dd / "Build/Products/Release"
    sparkle = dd / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    files = next((dd / "Build/Intermediates.noindex/Screendrop.build/Release/Screendrop.build").rglob("Sukusho.SwiftFileList"))
    sources = [line for line in files.read_text().splitlines() if Path(line).name != "AppEntry.swift"]
    assert all(Path(p).is_relative_to(root) for p in sources)
    # Darwin's NSTemporaryDirectory ignores TMPDIR here. Point only the CLI's shared result root at its HOME.
    original = root / "Screendrop/ImageOptimizer.swift"
    code = original.read_text()
    expr = "URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)"
    assert code.count(expr) == 1
    local = folder / original.name
    local.write_text(code.replace(expr, "FileManager.default.homeDirectoryForCurrentUser"))
    sources[sources.index(str(original))] = str(local)
    options = []
    for feature in ("DisableOutwardActorInference", "InferSendableFromCaptures", "GlobalActorIsolatedTypesUsability",
                    "MemberImportVisibility", "InferIsolatedConformances", "NonisolatedNonsendingByDefault"):
        options.extend(["-enable-upcoming-feature", feature])
    subprocess.run(["xcrun", "swiftc", "-O", "-whole-module-optimization", "-parse-as-library", "-module-name", "Screendrop",
                    "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos26.0", "-default-isolation", "MainActor",
                    "-enable-bare-slash-regex", *options, "-I", products, "-F", sparkle, "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", sparkle, products / "DockProgress.o", *sources,
                    root / "scripts/benchmark-image-optimizer.swift", "-o", binary], check=True)
elif action == "run":
    def clear():
        r = subprocess.run(["defaults", "delete", binary.name], capture_output=True, text=True)
        if r.returncode and "not found" not in r.stderr:
            sys.exit(r.stderr)
        (Path.home() / "Library/Preferences" / (binary.name + ".plist")).unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(dir=folder) as home:
        clear()
        try:
            subprocess.run([binary, *sys.argv[4:]], cwd=root, check=True,
                           env=dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, TMPDIR=home))
        finally:
            clear()
else:
    sys.exit("Expected build or run")
