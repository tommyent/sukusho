#!/usr/bin/env python3
"""Compile the Library inspector layout check against app sources and run it windowless, guarded."""
import datetime
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
build = derived / "LibraryInspectorLayoutCheck"
build.mkdir(exist_ok=True)
if Path("/private/tmp/screendrop-team/bench.lock").exists():
    sys.exit("Another benchmark owns bench.lock; wait before running.")

guard = build / "harness-guard.dylib"
if subprocess.run(["xcrun", "clang", "-dynamiclib", "-framework", "Security", "-framework", "CoreGraphics",
                   "-framework", "ApplicationServices", "-Wno-deprecated-declarations",
                   "-o", str(guard), str(repo / "scripts/harness-guard.c")]).returncode:
    sys.exit("Guard compile failed")

sources = sorted(str(p) for p in (repo / "Screendrop").rglob("*.swift") if p.name != "AppEntry.swift")
sources.append(str(repo / "scripts/check-library-inspector-layout.swift"))
source_list = build / "sources"
source_list.write_text("\n".join(sources))
binary = build / "check-library-inspector-layout"
command = [
    "lockf", "/private/tmp/screendrop-team/build.lock", "xcrun", "swiftc", "-parse-as-library",
    "-module-name", "Screendrop", "-target", f"{platform.machine()}-apple-macos27.0",
    "-default-isolation", "MainActor", "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-D", "DEBUG",
    "-I", str(products), str(products / "DockProgress.o"), "@" + str(source_list), "-o", str(binary),
]
with (build / "compile.log").open("w") as log:
    if subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT).returncode:
        sys.exit(f"Check compile failed: {build / 'compile.log'}")

env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(guard))
started = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
try:
    selftest = subprocess.run([str(binary), "guard-selftest"], env=env, capture_output=True, text=True, timeout=60)
    if selftest.returncode != 7:
        sys.exit(f"STOP: the guard isn't loaded (self-test exit {selftest.returncode})")
    print("PASS: guard self-test stopped a keychain call")
    with tempfile.TemporaryDirectory(prefix="sukusho-inspector-layout-", dir="/private/tmp") as root:
        result = subprocess.run([str(binary)], env=dict(env, CFFIXED_USER_HOME=root), timeout=180)
finally:
    # UserDefaults ignores CFFIXED_USER_HOME: the check empties this binary's own domain,
    # and cfprefsd leaves its empty plist in the real home, sometimes seconds later.
    plist = Path.home() / "Library/Preferences" / f"{binary.name}.plist"
    plist.unlink(missing_ok=True)
prompts = subprocess.run(["/usr/bin/log", "show", "--start", started, "--style", "compact", "--predicate",
                          'process == "securityd" AND eventMessage CONTAINS "keychain prompt"'],
                         capture_output=True, text=True).stdout.count("keychain prompt")
plist.unlink(missing_ok=True)
if prompts:
    sys.exit(f"STOP: {prompts} keychain prompt(s) during the run")
if result.returncode == 7:
    sys.exit("EXCLUDED: the inspector touched the keychain or a permission API; review it from source")
sys.exit(result.returncode)
