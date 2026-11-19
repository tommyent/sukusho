#!/bin/zsh
# Chip's paper grain stays on the paper: compiles check-chip-paper.swift with today's app sources, renders its cards
# twice, from a folder with PaperGrain.png beside the binary (where the app's Bundle.main lookup finds it) and from
# one without (the app then draws no grain), and compares the two. Never launches the app.
# Usage: scripts/check-chip-paper.sh <Dev DerivedData folder>
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=${1:?"usage: $0 <Dev DerivedData folder>"}
PRODUCTS="$DERIVED/Build/Products/Debug Dev"
SPARKLE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
[[ -f "$PRODUCTS/DockProgress.o" ]] || { echo "Chip paper check: build the Screendrop Dev scheme into $DERIVED first"; exit 1; }
OUT=$(mktemp -d /private/tmp/chip-paper-check.XXXXXX)
trap 'trash "$OUT"' EXIT
mkdir -p "$OUT/home" "$OUT/with/out" "$OUT/without/out"
# Today's sources as they are now, so edits made while it compiles can't mix in.
ditto Screendrop "$OUT/src/Screendrop"
ditto scripts/check-chip-paper.swift "$OUT/src/check-chip-paper.swift"
{ find "$OUT/src/Screendrop" -name '*.swift' ! -name AppEntry.swift; print -r -- "$OUT/src/check-chip-paper.swift"; } >| "$OUT/sources"
xcrun swiftc -parse-as-library -module-name Screendrop -target "$(uname -m)-apple-macos26.0" \
    -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -D DEBUG \
    -I "$PRODUCTS" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
    "$PRODUCTS/DockProgress.o" "@$OUT/sources" -o "$OUT/with/check-chip-paper" >| "$OUT/compile.log" 2>&1 \
    || { echo "Chip paper check: compiling failed"; tail -20 "$OUT/compile.log"; exit 1; }
cp "$OUT/with/check-chip-paper" "$OUT/without/"
cp "$OUT/src/Screendrop/PaperGrain.png" "$OUT/with/"
CFFIXED_USER_HOME="$OUT/home" "$OUT/with/check-chip-paper" render "$OUT/with/out"
CFFIXED_USER_HOME="$OUT/home" "$OUT/without/check-chip-paper" render "$OUT/without/out"
"$OUT/with/check-chip-paper" compare "$OUT/with/out" "$OUT/without/out"
