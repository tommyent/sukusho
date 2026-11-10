#!/bin/zsh
# Makes the site's images from the app repo's README screenshots and the brand exports. Re-run after retaking them.
set -euo pipefail
cd "$(dirname "$0")/.."
SHOTS=../app/docs/screenshots
BRAND=../brand
OUT=assets/img
mkdir -p "$OUT"

# Full screenshots, at most 1600 px wide
for name in library studio editor share-page gallery gallery-lightbox comments agent-prompt share-options; do
    sips -Z 1600 -s format jpeg -s formatOptions 78 "$SHOTS/$name.jpg" --out "$OUT/$name.jpg" >/dev/null
done
sips -s format jpeg -s formatOptions 78 "$SHOTS/scrolling-capture.png" --out "$OUT/scrolling-capture.jpg" >/dev/null
sips -Z 1600 "$OUT/scrolling-capture.jpg" >/dev/null

# crop <source> <x> <y> <w> <h> <out> [max size]: a region in the source's own pixels
crop() {
    sips -c "$5" "$4" --cropOffset "$3" "$2" -s format jpeg -s formatOptions 80 "$1" --out "$6" >/dev/null
    [[ -n "${7:-}" ]] && sips -Z "$7" "$6" >/dev/null
    return 0
}

# The Library's ten cards (library.jpg is 2360 x 1520)
L=$SHOTS/library.jpg
crop $L 530 139 342 230 "$OUT/card-slow-roads-walkthrough.jpg"
crop $L 939 139 342 230 "$OUT/card-first-take.jpg"
crop $L 1352 139 338 210 "$OUT/card-lake-at-dawn.jpg"
crop $L 530 507 342 230 "$OUT/card-full-page.jpg"
crop $L 939 507 342 230 "$OUT/card-home-page.jpg"
crop $L 1365 507 312 233 "$OUT/card-northern-lights.jpg"
crop $L 530 877 342 231 "$OUT/card-meadow-path.jpg"
crop $L 955 877 312 231 "$OUT/card-coast-at-sunset.jpg"
crop $L 1365 877 312 231 "$OUT/card-desert-road.jpg"
crop $L 545 1246 313 211 "$OUT/card-field-kit.jpg"

# The Share Options sheet alone (share-options.jpg is 1405 x 801)
crop $SHOTS/share-options.jpg 421 52 563 700 "$OUT/share-options-sheet.jpg"

# The marked-up Slow Roads page from the editor (editor.jpg is 2200 x 1520): the hero strip pans across it
crop $SHOTS/editor.jpg 184 371 1274 1010 "$OUT/markup.jpg" 1400
# The Bug Report frame strip at the foot of agent-prompt.jpg (2360 x 2306); x is 1 because sips ignores
# --cropOffset when x is 0
crop $SHOTS/agent-prompt.jpg 1 1568 2359 738 "$OUT/bug-report-strip.jpg" 1600
# The whole stitched demo page that the Scrolling Capture viewer opens, 1400 px wide
sips --resampleWidth 1400 -s format jpeg -s formatOptions 78 ../notes/readme-assets/captures/screenshot_2026-10-12_065921.png --out "$OUT/scrolling-capture-full.jpg" >/dev/null
# Not made here: recordings, uploads, file-requests, tags and clean-desktop-off/-on were taken in the VMPal VM on
# 2026-11-10 and copied in by hand from ../site-mockup/Sukusho modernist redesign/img/v2/ (recordings and uploads
# from its retake/ folder, made with the build that names files Sukusho).

# The link preview card: the top of the marked-up page, 1200 x 630
crop $SHOTS/editor.jpg 184 371 1274 669 assets/og.jpg 1200

# Icons
sips -Z 180 "$BRAND/Exports/sukusho-macos-27-1024.png" --out assets/apple-touch-icon.png >/dev/null
cp "$BRAND/Exports/Sukusho.iconset/icon_32x32@2x.png" assets/favicon.png
ls -la "$OUT" assets/*.png
