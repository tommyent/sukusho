#!/usr/bin/env python3
"""Link the fixture to an optimized, testable Release build, without the app entry point."""
from contextlib import contextmanager
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
dd = Path(sys.argv[1]).resolve()
arch = platform.machine()
products = dd / "Build/Products/Release"
objects = dd / f"Build/Intermediates.noindex/Screendrop.build/Release/Screendrop.build/Objects-normal/{arch}"
sparkle = dd / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if not (objects / "AppEntry.o").exists():
    sys.exit("Build Release with SWIFT_COMPILATION_MODE=singlefile ENABLE_TESTABILITY=YES first.")

binary = dd / "LibraryEditorBenchmark"

def clear_defaults():
    # cfprefsd ignores CFFIXED_USER_HOME. Clear only this CLI's domain, including its cached values.
    result = subprocess.run(["/usr/bin/defaults", "delete", binary.name], capture_output=True, text=True)
    if result.returncode and "not found" not in result.stderr:
        sys.exit("Could not reset benchmark defaults: " + result.stderr)
    (Path.home() / "Library/Preferences" / f"{binary.name}.plist").unlink(missing_ok=True)

@contextmanager
def clean_defaults():
    clear_defaults()
    try:
        yield
    finally:
        clear_defaults()

subprocess.run([
    "xcrun", "swiftc", "-O", "-parse-as-library", "-target", f"{arch}-apple-macos26.0",
    "-I", products, "-I", objects, "-F", sparkle, "-framework", "Sparkle",
    "-Xlinker", "-rpath", "-Xlinker", sparkle, products / "DockProgress.o",
    repo / "scripts/benchmark-library-editor.swift",
    *(o for o in sorted(objects.glob("*.o")) if o.name != "AppEntry.o"), "-o", binary,
], check=True)
with tempfile.TemporaryDirectory(prefix="library-editor-", dir=dd) as home:
    env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, TMPDIR=home)
    with clean_defaults():
        subprocess.run(["/usr/bin/time", "-l", binary, *sys.argv[2:]], cwd=repo, check=True, env=env)
    if sys.argv[2:] == ["library"]:
        ns = []
        for _ in range(12):
            with clean_defaults():
                ns.append(int(subprocess.check_output([binary, "first-library"], cwd=repo, env=env)))
        ms = sorted(t / 1e6 for t in ns[1:])
        print(f"First Library model ready (fresh process) median {ms[5]:.3f} ms, p95 {ms[-1]:.3f} ms")
