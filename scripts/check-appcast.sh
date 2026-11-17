#!/bin/zsh
# Dry run of scripts/appcast.sh: no release, no Keychain, nothing published. It makes a stand-in Sukusho.app with a
# throwaway update key, puts it in a DMG, and makes two feeds in a temporary folder: a beta added to a published
# feed, and a stable release. It then checks what release.sh relies on.
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

# A beta: one more item, on the beta channel, and every published item still there, byte for byte.
build 9.9.0-beta.1 "9.9.0 beta 1" 99.991231.2359
VERSION=9.9.0-beta.1 SHOWN="9.9.0 beta 1" BUILD=99.991231.2359 BETA=1 FEED="$WORK/published.xml" \
    SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" scripts/appcast.sh "$WORK/9.9.0-beta.1"
BETA_FEED="$WORK/9.9.0-beta.1/appcast.xml"
(( $(count "//item[*[local-name()='channel']='beta']" "$BETA_FEED") == 1 )) || fail "the beta feed should hold one beta item"
grep -F 'sparkle:edSignature=' "$WORK/published.xml" | while read -r line; do
    grep -qF -- "$line" "$BETA_FEED" || fail "a published item's download or signature changed in the beta feed"
done

# A stable release: its feed is that release alone, with no channel.
build 9.9.0 9.9.0 99.991231.2400
VERSION=9.9.0 SHOWN=9.9.0 BUILD=99.991231.2400 SPARKLE_BIN="$SPARKLE_BIN" APPCAST_KEY_FILE="$WORK/key" \
    scripts/appcast.sh "$WORK/9.9.0"
(( $(count '//item' "$WORK/9.9.0/appcast.xml") == 1 )) || fail "a stable feed should hold one item"

# The checks must also refuse: a beta item claimed for a stable release is caught.
if VERSION=9.9.0-beta.1 SHOWN="9.9.0 beta 1" BUILD=99.991231.2359 FEED="$WORK/published.xml" SPARKLE_BIN="$SPARKLE_BIN" \
    APPCAST_KEY_FILE="$WORK/key" scripts/appcast.sh "$WORK/9.9.0-beta.1" 2> "$WORK/refused.txt"; then
    fail "appcast.sh accepted an item on the beta channel as a stable release"
fi
print -r -- "check-appcast: passed. The feeds are in $WORK"
