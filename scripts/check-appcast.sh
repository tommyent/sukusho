#!/bin/zsh
# Dry run of scripts/appcast.sh: no release, no Keychain, nothing published. It makes a stand-in Sukusho.app with a
# throwaway update key, puts it in a DMG, and makes feeds in a temporary folder: a beta added to the published
# feed, a second beta added to that, and a stable release. It then checks what release.sh relies on, and that
# appcast.sh refuses what it must.
#   scripts/check-appcast.sh <folder with Sparkle's generate_appcast> [published appcast.xml]
# The folder is <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin of any build. Without a published
# feed, the local gh-pages branch's is used. Needs an openssl that knows Ed25519 (Homebrew's does).
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { print -u2 -- "check-appcast: $1"; exit 1 }
SPARKLE_BIN="${1:?usage: scripts/check-appcast.sh <folder with generate_appcast> [published appcast.xml]}"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "no generate_appcast in $SPARKLE_BIN"
WORK="$(mktemp -d)"
if [[ -n "${2:-}" ]]; then cp "$2" "$WORK/published.xml"; else git show gh-pages:appcast.xml > "$WORK/published.xml"; fi

OPENSSL=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if "$candidate" genpkey -algorithm ed25519 -outform DER -out "$WORK/key.der" 2> /dev/null; then OPENSSL="$candidate"; break; fi
done
[[ -n "$OPENSSL" ]] || fail "no openssl here can make an Ed25519 key"
# Sparkle's key file is the 32-byte seed in base64; the app carries the 32-byte public key in base64.
tail -c 32 "$WORK/key.der" | base64 > "$WORK/key"
PUBLIC="$("$OPENSSL" pkey -inform DER -in "$WORK/key.der" -pubout -outform DER | tail -c 32 | base64)"

build() {   # version in file names, version shown, build number: a signed stand-in app in a DMG, with notes
    local updates="$WORK/$1"
    mkdir -p "$WORK/app-$1/Sukusho.app/Contents/MacOS" "$updates"
    cp /usr/bin/true "$WORK/app-$1/Sukusho.app/Contents/MacOS/Sukusho"
    local plist="$WORK/app-$1/Sukusho.app/Contents/Info.plist"
    plutil -create xml1 "$plist"
    for pair in CFBundleIdentifier=com.tommyent.Sukusho CFBundleName=Sukusho CFBundleExecutable=Sukusho CFBundlePackageType=APPL \
        "CFBundleShortVersionString=$2" "CFBundleVersion=$3" LSMinimumSystemVersion=26.0 "SUPublicEDKey=$PUBLIC"; do
        plutil -insert "${pair%%=*}" -string "${pair#*=}" "$plist"
    done
    codesign --force --sign - "$WORK/app-$1/Sukusho.app" 2> /dev/null
    hdiutil create -quiet -volname "Sukusho $2" -srcfolder "$WORK/app-$1" -format UDZO -o "$updates/Sukusho-$1.dmg"
    print -r -- "# Sukusho $2"$'\n\n'"A dry run's notes." > "$updates/Sukusho-$1.md"
}
count() { xmllint --xpath "count($1)" "$2" }

# A beta: one more item, on the beta channel, and every item of the feed it was added to still there, byte for
# byte. Counted against that feed, which may hold betas already: the published one does once beta 1 is out.
beta() {   # version in file names, version shown, build number, the feed to add to
    build "$1" "$2" "$3"
    VERSION="$1" SHOWN="$2" BUILD="$3" BETA=1 FEED="$4" SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" \
        scripts/appcast.sh "$WORK/$1"
    local betas="//item[*[local-name()='channel']='beta']" made="$WORK/$1/appcast.xml"
    (( $(count "$betas" "$made") == $(count "$betas" "$4") + 1 )) || fail "$2 should add one beta item to its feed"
    grep -F 'sparkle:edSignature=' "$4" | while read -r line; do
        grep -qF -- "$line" "$made" || fail "an item's download or signature changed when $2 was added"
    done
}
beta 9.9.0-beta.1 "9.9.0 beta 1" 99.991231.2359 "$WORK/published.xml"
# The next beta joins a feed that already holds one, and the first stays as it is.
beta 9.9.0-beta.2 "9.9.0 beta 2" 99.991231.2399 "$WORK/9.9.0-beta.1/appcast.xml"
(( $(count "//item[*[local-name()='channel']='beta']" "$WORK/9.9.0-beta.2/appcast.xml") >= 2 )) || fail "the second beta's feed lost the first beta"

# A stable release: its feed is that release alone, with no channel.
build 9.9.0 9.9.0 99.991231.2400
VERSION=9.9.0 SHOWN=9.9.0 BUILD=99.991231.2400 SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" \
    scripts/appcast.sh "$WORK/9.9.0"
(( $(count '//item' "$WORK/9.9.0/appcast.xml") == 1 )) || fail "a stable feed should hold one item"

# The checks must also refuse, each for its own reason (a refusal for another reason proves nothing).
refused() {   # what was tried, the words its refusal must hold; the attempt's output is in refused.txt
    grep -qF -- "$2" "$WORK/refused.txt" || fail "$1 was refused, but not for the reason expected: $(< "$WORK/refused.txt")"
}
# A beta's files without BETA, in a folder with nothing else in it, as release.sh's is: no feed is made. Without
# the check on names this came out as a signed stable item, which every copy would be offered.
mkdir "$WORK/fresh"
cp "$WORK/9.9.0-beta.1/Sukusho-9.9.0-beta.1.dmg" "$WORK/9.9.0-beta.1/Sukusho-9.9.0-beta.1.md" "$WORK/fresh/"
if VERSION=9.9.0-beta.1 SHOWN="9.9.0 beta 1" BUILD=99.991231.2359 SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" \
    scripts/appcast.sh "$WORK/fresh" > "$WORK/refused.txt" 2>&1; then
    fail "appcast.sh made a stable feed from a beta's files"
fi
refused "a beta without BETA" "a stable release is named"
[[ ! -e "$WORK/fresh/appcast.xml" ]] || fail "a refused beta still left a feed behind"
# The other way round: a stable release's files with BETA.
if VERSION=9.9.0 SHOWN=9.9.0 BUILD=99.991231.2400 BETA=1 FEED="$WORK/published.xml" SPARKLE_BIN="$SPARKLE_BIN" \
    APPCAST_KEY_FILE="$WORK/key" scripts/appcast.sh "$WORK/9.9.0" > "$WORK/refused.txt" 2>&1; then
    fail "appcast.sh put a stable release on the beta channel"
fi
refused "a stable release with BETA" "a beta is named"
# An item that is already on the beta channel in the folder's feed, made again as a stable release: Sparkle
# keeps the channel on an item it updates, and the check on the new item catches it.
sed -i '' 's|<sparkle:version>99.991231.2400</sparkle:version>|&<sparkle:channel>beta</sparkle:channel>|' "$WORK/9.9.0/appcast.xml"
(( $(count "//item[*[local-name()='channel']='beta']" "$WORK/9.9.0/appcast.xml") == 1 )) || fail "the dry run couldn't mark its stable item as a beta"
if VERSION=9.9.0 SHOWN=9.9.0 BUILD=99.991231.2400 SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" \
    scripts/appcast.sh "$WORK/9.9.0" > "$WORK/refused.txt" 2>&1; then
    fail "appcast.sh accepted an item on the beta channel as a stable release"
fi
refused "a stable item on the beta channel" "the new item's channel is 'beta'"
# release.sh refuses a counter the app wouldn't read as a beta's, before it looks at anything else (Sol, round 4).
# PERSONAL=1 too: should a counter ever get through, BETA with PERSONAL stops the script before it builds anything.
for counter in 0 01 010 1x -1 '1 ' '١' '１'; do
    if BETA="$counter" PERSONAL=1 scripts/release.sh > "$WORK/refused.txt" 2>&1; then fail "release.sh took BETA='$counter'"; fi
    refused "BETA='$counter'" "BETA is the beta's number"
done
# And a good counter gets past that check (it stops later, for its own reasons, before any build).
BETA=12 PERSONAL=1 scripts/release.sh > "$WORK/refused.txt" 2>&1 || true
if grep -qF "BETA is the beta's number" "$WORK/refused.txt"; then fail "release.sh refused BETA=12"; fi
print -r -- "check-appcast: passed. The feeds are in $WORK"
