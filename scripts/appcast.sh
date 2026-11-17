#!/bin/zsh
# Makes a release's Sparkle feed in a folder that holds the stapled DMG and its notes, then checks the new item.
# scripts/release.sh runs it. Run by hand it is only for a dry run, with a throwaway key in APPCAST_KEY_FILE.
#   VERSION      the version in file names and links: 1.3.0, or 1.3.0-beta.1
#   SHOWN        the version people see: 1.3.0, or "1.3.0 beta 1"
#   BUILD        the build number, which is what Sparkle compares
#   BETA         set for a beta: the item goes on Sparkle's "beta" channel, which only copies with Settings ›
#                About › Get beta updates on are offered, and the feed's other items stay as they are
#   FEED         for a beta, the published appcast.xml to add the item to
#   SPARKLE_BIN  the folder with generate_appcast; KEY_ACCOUNT the Keychain account of the EdDSA key
set -euo pipefail
fail() { print -u2 -- "appcast: $1"; exit 1 }
UPDATES="${1:?usage: scripts/appcast.sh <the folder with the DMG and its notes>}"
: "${VERSION:?}" "${SHOWN:?}" "${BUILD:?}" "${SPARKLE_BIN:?}"
DMG="$UPDATES/Sukusho-$VERSION.dmg"
APPCAST="$UPDATES/appcast.xml"
[[ -s "$DMG" && -s "$UPDATES/Sukusho-$VERSION.md" ]] || fail "$UPDATES needs Sukusho-$VERSION.dmg and Sukusho-$VERSION.md"

flags=(--maximum-deltas 0 --embed-release-notes
    --download-url-prefix "https://github.com/tommyent/sukusho/releases/download/v$VERSION/"
    --full-release-notes-url "https://github.com/tommyent/sukusho/releases"
    --link "https://tommyent.github.io/sukusho/")
if [[ -n "${APPCAST_KEY_FILE:-}" ]]; then
    flags+=(--ed-key-file "$APPCAST_KEY_FILE")
else
    flags+=(--account "${KEY_ACCOUNT:?}")
fi
count() { xmllint --xpath "count($1)" "$2" }
before=0
if [[ -n "${BETA:-}" ]]; then
    # A beta joins the feed people already have. Its stable items stay, so a copy that doesn't take betas is
    # offered exactly what it was offered before.
    [[ -s "${FEED:-}" ]] || fail "a beta needs the published appcast.xml to add to (FEED)"
    cp "$FEED" "$APPCAST"
    before="$(count '//item' "$APPCAST")"
    flags+=(--channel beta --maximum-versions 0)
fi
"$SPARKLE_BIN/generate_appcast" $flags "$UPDATES"

# The new item, found by its build number, so another item's values can't stand in for it.
item() { xmllint --xpath "string(//item[*[local-name()='version']='$BUILD']$1)" "$APPCAST" }
want() { [[ "$2" == "$3" ]] || fail "the new item's $1 is '$2', expected '$3'" }
want "version shown" "$(item "/*[local-name()='shortVersionString']")" "$SHOWN"
want "download" "$(item "/enclosure/@url")" "https://github.com/tommyent/sukusho/releases/download/v$VERSION/Sukusho-$VERSION.dmg"
want "length" "$(item "/enclosure/@length")" "$(stat -f %z "$DMG")"
want "notes format" "$(item "/description/@*[local-name()='format']")" markdown
[[ -n "$(item "/enclosure/@*[local-name()='edSignature']")" ]] || fail "the new item has no EdDSA signature"
[[ -n "$(item "/*[local-name()='minimumSystemVersion']")" ]] || fail "the new item names no minimum macOS"
if [[ -n "${BETA:-}" ]]; then
    want "channel" "$(item "/*[local-name()='channel']")" beta
    want "number of items" "$(count '//item' "$APPCAST")" "$(( before + 1 ))"
    (( $(count "//item[not(*[local-name()='channel'])]" "$APPCAST") >= 1 )) \
        || fail "the feed has no stable item left: copies that don't take betas would be offered nothing"
else
    want "channel" "$(item "/*[local-name()='channel']")" ""
fi
print -r -- "appcast: $SHOWN ($BUILD)${BETA:+ on the beta channel} in $APPCAST"
