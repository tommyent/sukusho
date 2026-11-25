#!/usr/bin/env python3
"""Under heavy: build-scroll-replay.py <git ref|working> <output> [Release DerivedData].

Default: instrument a disposable copy of the four production sources for stage timings.
With DerivedData: compile them uninstrumented alongside the full app's Swift sources
and built dependencies, replacing AppEntry with the CLI. Both use optimized WMO.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

revision, output = sys.argv[1:3]
dd = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else None
root = Path(__file__).resolve().parents[1]
output = Path(output).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=output.parent) as temp:
    sources = []
    for part in ("Raster", "OffsetEstimator", "OffsetVerifier", "FrameStitcher"):
        name = f"ScrollingCapture{part}.swift"
        source = Path("Screendrop") / name
        text = (root/source).read_text() if revision == "working" else subprocess.check_output(
            ["git", "show", f"{revision}:{source}"], cwd=root, text=True)
        if part == "FrameStitcher" and dd is None:
            for before, after in [
                ("    private let width:", "    private(set) var visionNS: UInt64 = 0\n    private let width:"),
                ("        let candidate = ScrollingCaptureOffsetEstimator.candidate",
                 "        let begin = DispatchTime.now().uptimeNanoseconds\n        let candidate = ScrollingCaptureOffsetEstimator.candidate"),
                ("        let wasUpward = lastWasUpward",
                 "        visionNS = DispatchTime.now().uptimeNanoseconds - begin\n        let wasUpward = lastWasUpward"),
            ]:
                if text.count(before) != 1:
                    sys.exit("Stitcher timing anchor changed: " + before)
                text = text.replace(before, after)
        destination = Path(temp) / name
        destination.write_text(text)
        sources.append(destination)
    options = ["-D", "SCROLL_STAGE_CLOCK"]
    if dd:
        products = dd / "Build/Products/Release"
        sparkle = dd / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
        filelist = next((dd / "Build/Intermediates.noindex/Screendrop.build/Release/Screendrop.build").rglob("Sukusho.SwiftFileList"))
        replaced = {"AppEntry.swift", *(path.name for path in sources)}
        sources.extend(Path(line) for line in filelist.read_text().splitlines() if Path(line).name not in replaced)
        options = ["-module-name", "Screendrop", "-swift-version", "5", "-default-isolation", "MainActor",
                   "-enable-bare-slash-regex", "-I", products, "-F", sparkle, "-framework", "Sparkle",
                   "-Xlinker", "-rpath", "-Xlinker", sparkle, products / "DockProgress.o"]
        for feature in ("DisableOutwardActorInference", "InferSendableFromCaptures", "GlobalActorIsolatedTypesUsability",
                        "MemberImportVisibility", "InferIsolatedConformances", "NonisolatedNonsendingByDefault"):
            options.extend(["-enable-upcoming-feature", feature])
    subprocess.run(["xcrun", "swiftc", "-O", "-whole-module-optimization", "-target", "arm64-apple-macos26.0",
                    "-parse-as-library", *options, *sources,
                    root/"scripts/benchmark-scroll-replay.swift", "-o", output], check=True)
