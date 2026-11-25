#!/bin/zsh
# Checks the command palette against the app itself, without a window (check-command-palette.swift): the real host over
# the Library's model, a Studio model on a bare movie, the theme try-on and every command's handler. Compiled with the
# app's sources as render-command-palette.sh compiles them, and run in a fresh home. Never launches the app.
# Usage: scripts/check-command-palette.sh <Dev DerivedData folder>
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=${1:?"usage: $0 <Dev DerivedData folder>"}
PRODUCTS="$DERIVED/Build/Products/Debug Dev"
SPARKLE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
[[ -f "$PRODUCTS/DockProgress.o" ]] || { echo "Palette check: build the Screendrop Dev scheme into $DERIVED first"; exit 1; }
WORK=$(mktemp -d /private/tmp/palette-check.XXXXXX)
# The binary's own preferences live in the real home whatever the fresh one says; it empties them, this removes the file.
PLIST=~/Library/Preferences/check-command-palette.plist
trap 'trash "$WORK"; [[ -e $PLIST ]] && trash $PLIST' EXIT
mkdir -p "$WORK/home"
{ find Screendrop -name '*.swift' ! -name AppEntry.swift; print -r -- scripts/check-command-palette.swift; } >| "$WORK/sources"
xcrun swiftc -parse-as-library -module-name Screendrop -target "$(uname -m)-apple-macos26.0" \
    -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -D DEBUG \
    -I "$PRODUCTS" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
    "$PRODUCTS/DockProgress.o" "@$WORK/sources" -o "$WORK/check-command-palette" >| "$WORK/build.log" 2>&1 \
    || { echo "Palette check: compiling failed"; grep -E 'error:' "$WORK/build.log" | head -20; exit 1; }
CFFIXED_USER_HOME="$WORK/home" PALETTE_CHECK_HOME="$WORK/home" "$WORK/check-command-palette"
