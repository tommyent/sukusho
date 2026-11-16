#!/bin/zsh
# Builds SukushoPasteboardProbe.app and probe-write into <out-dir>, signed with
# this Mac's first Developer ID identity (the identity personal builds use).
# Usage: scripts/pasteboard-probe/build.sh <out-dir> [build-number]
set -euo pipefail
out=${1:?usage: build.sh <out-dir> [build-number]}
build=${2:-1}
src=${0:A:h}
app="$out/SukushoPasteboardProbe.app"
identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')
[[ -n $identity ]] || { echo "no Developer ID Application identity" >&2; exit 1; }

mkdir -p "$app/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 \
  "$src/PasteboardProbe.swift" -o "$app/Contents/MacOS/SukushoPasteboardProbe"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 \
  "$src/ProbeWrite.swift" -o "$out/probe-write"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tommyent.Sukusho.pasteboard-probe</string>
  <key>CFBundleName</key><string>Sukusho Pasteboard Probe</string>
  <key>CFBundleExecutable</key><string>SukushoPasteboardProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign "$identity" "$out/probe-write"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --strict "$app" && echo "built $app (build $build)"
