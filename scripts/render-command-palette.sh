#!/bin/zsh
# Draws the command palette's states to PNGs, light and dark, in Classic, Chip and Glass (render-command-palette.swift),
# compiled with the app's sources as check-classic-render.sh compiles them. Never launches the app; a fresh home keeps
# the renders' theme choices out of yours. Glass's frost and the Accessibility settings need the live app.
# Usage: scripts/render-command-palette.sh <Dev DerivedData folder> <output folder>
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=${1:?"usage: $0 <Dev DerivedData folder> <output folder>"}
OUTPUT=${2:?"usage: $0 <Dev DerivedData folder> <output folder>"}
PRODUCTS="$DERIVED/Build/Products/Debug Dev"
SPARKLE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
[[ -f "$PRODUCTS/DockProgress.o" ]] || { echo "Palette render: build the Screendrop Dev scheme into $DERIVED first"; exit 1; }
WORK=$(mktemp -d /private/tmp/palette-render.XXXXXX)
trap 'trash "$WORK"' EXIT
mkdir -p "$WORK/home" "$OUTPUT"
{ find Screendrop -name '*.swift' ! -name AppEntry.swift; print -r -- scripts/render-command-palette.swift; } >| "$WORK/sources"
xcrun swiftc -parse-as-library -module-name Screendrop -target "$(uname -m)-apple-macos26.0" \
    -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -D DEBUG \
    -I "$PRODUCTS" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
    "$PRODUCTS/DockProgress.o" "@$WORK/sources" -o "$WORK/render" >| "$WORK/build.log" 2>&1 \
    || { echo "Palette render: compiling failed"; grep -E 'error:' "$WORK/build.log" | head -20; exit 1; }
CFFIXED_USER_HOME="$WORK/home" "$WORK/render" "$OUTPUT"
