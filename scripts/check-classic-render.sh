#!/bin/zsh
# Classic draws byte for byte as beta 5 did, before the theme layer: check-classic-render.swift's fixture (every chrome
# colour Classic holds, the workspace ground, list rows, marks, and the grid card previews at 140, 220 and 320 pt in
# four states), rendered with the sources at BASE and with today's, must give identical RGBA bytes, light and dark,
# at 1x and 2x. ImageRenderer can't draw materials or system controls, so the toolbar, sidebar list and Settings'
# forms aren't in it. A deliberate change to Classic's look moves BASE to the commit that made it.
# Usage: scripts/check-classic-render.sh <Dev DerivedData folder> [base revision]. Never launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED=${1:?"usage: $0 <Dev DerivedData folder> [base revision]"}
BASE=${2:-07bd481}
PRODUCTS="$DERIVED/Build/Products/Debug Dev"
SPARKLE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
[[ -f "$PRODUCTS/DockProgress.o" ]] || { echo "Classic render check: build the Screendrop Dev scheme into $DERIVED first"; exit 1; }
git cat-file -e "$BASE^{commit}" || { echo "Classic render check: $BASE is not in this checkout's history"; exit 1; }
OUT=$(mktemp -d /private/tmp/classic-render.XXXXXX)
trap 'trash "$OUT"' EXIT
mkdir -p "$OUT/base" "$OUT/home" "$OUT/base-out" "$OUT/head-out"
git archive "$BASE" Screendrop | tar -x -C "$OUT/base"
# Today's sources and the fixture as they are now, so edits made while it compiles can't mix in.
ditto Screendrop "$OUT/head/Screendrop"
ditto scripts/check-classic-render.swift "$OUT/check-classic-render.swift"

build() {   # sources folder, output binary
    { find "$1" -name '*.swift' ! -name AppEntry.swift; print -r -- "$OUT/check-classic-render.swift"; } >| "$2.sources"
    xcrun swiftc -parse-as-library -module-name Screendrop -target "$(uname -m)-apple-macos26.0" \
        -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
        -enable-upcoming-feature NonisolatedNonsendingByDefault -D DEBUG \
        -I "$PRODUCTS" -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
        "$PRODUCTS/DockProgress.o" "@$2.sources" -o "$2" >| "$2.log" 2>&1 \
        || { echo "Classic render check: compiling $1 failed, see $2.log"; tail -20 "$2.log"; return 1; }
}
build "$OUT/base/Screendrop" "$OUT/base-render" & base=$!
build "$OUT/head/Screendrop" "$OUT/head-render" & head=$!
compiled=1
wait $base || compiled=0
wait $head || compiled=0
(( compiled )) || exit 1
# A fresh home: no saved theme or workspace choice, so both draw their defaults.
CFFIXED_USER_HOME="$OUT/home" "$OUT/base-render" "$OUT/base-out" >/dev/null
CFFIXED_USER_HOME="$OUT/home" "$OUT/head-render" "$OUT/head-out" >/dev/null
failed=0
for file in "$OUT"/base-out/*.rgba; do
    name=${file:t:r}
    cmp -s "$file" "$OUT/head-out/${name}.rgba" || { echo "Classic render check FAILED: $name differs from $BASE"; failed=1; }
done
if (( failed )); then
    keep=$(mktemp -d /private/tmp/classic-render-diff.XXXXXX)
    cp "$OUT"/base-out/*.png "$keep/" && for f in "$OUT"/head-out/*.png; do cp "$f" "$keep/head-${f:t}"; done
    echo "Renders kept in $keep (base: name.png, today: head-name.png)"
    exit 1
fi
echo "Classic render check passed: $(ls "$OUT"/base-out/*.rgba | wc -l | tr -d ' ') renders identical to $BASE, light and dark, 1x and 2x"
