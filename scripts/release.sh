#!/bin/zsh
# Official Sukusho build: a Developer ID signature with the hardened runtime, then a notarized, stapled app inside a
# notarized, stapled DMG, its checksum, Sparkle's appcast and a manifest, in a new folder under ../builds.
# Fails closed: it exits non-zero unless Apple accepts both submissions, both staples validate and Gatekeeper
# accepts the app and the DMG as notarized.
# Needs one "Developer ID Application" identity (DEVELOPER_ID picks one when there are several), a notarytool
# keychain profile (NOTARY_PROFILE, default "notary"), Sparkle's EdDSA key in the login Keychain under the account
# com.tommyent.Sukusho, and the release notes in docs/releases/<version>.md (MARKETING_VERSION in the project).
# The build number is 32.YYMMDD.HHMM in UTC, which Sparkle compares and which only ever grows.
# scripts/site.sh then puts the appcast on the gh-pages branch.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-notary}"
BUNDLE_ID=com.tommyent.Sukusho
KEY_ACCOUNT=$BUNDLE_ID   # Sparkle's EdDSA key, kept apart from other apps' keys
FEED=https://tommyent.github.io/sukusho/appcast.xml
fail() { print -u2 -- "release: $1"; exit 1 }

git diff --quiet HEAD -- || fail "commit the tracked changes first: a release is built from a commit"
# Folder-synchronized groups compile every file in Screendrop/, so untracked files would ship unnamed by the commit.
[[ -z "$(git status --porcelain -- Screendrop SukushoMCP Screendrop.xcodeproj scripts docs/releases)" ]] \
    || fail "commit or remove the untracked files first: a release is built from a commit"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    IDS=("${(@f)$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)"$/\1/p' | sort -u)}")
    (( ${#IDS} == 1 )) && [[ -n "${IDS[1]}" ]] || fail "set DEVELOPER_ID: expected one Developer ID Application identity"
    DEVELOPER_ID="${IDS[1]}"
fi
TEAM="${${DEVELOPER_ID##*\(}%\)}"

VERSIONS=("${(@f)$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Screendrop.xcodeproj/project.pbxproj | sort -u)}")
(( ${#VERSIONS} == 1 )) || fail "the configurations disagree on MARKETING_VERSION: ${VERSIONS[*]}"
VERSION="${VERSIONS[1]}"
NOTES="docs/releases/$VERSION.md"
[[ -s "$NOTES" ]] || fail "write the release notes first: $NOTES"
BUILD="32.$(date -u +%y%m%d.%H%M)"

OUT="$(mktemp -d "../builds/release-$VERSION.XXXXXX")"
OUT="${OUT:A}"
DD="${OUT:h}/dd-release"   # kept between releases so packages resolve once; the build itself is clean
print -r -- "release: $VERSION ($BUILD) into $OUT"
xcodebuild clean build -project Screendrop.xcodeproj -scheme Screendrop -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" PROVISIONING_PROFILE_SPECIFIER= \
    OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CURRENT_PROJECT_VERSION="$BUILD" \
    STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES CLANG_COVERAGE_MAPPING=NO CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO \
    > "$OUT/build.log" 2>&1 || fail "build failed, see $OUT/build.log"
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"   # this build's own copy, never another folder's

APP="$OUT/Sukusho.app"
ditto "$DD/Build/Products/Release/Sukusho.app" "$APP"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" }
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "bundle ID is $(plist CFBundleIdentifier)"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" && "$(plist CFBundleVersion)" == "$BUILD" ]] \
    || fail "the app says $(plist CFBundleShortVersionString) ($(plist CFBundleVersion)), expected $VERSION ($BUILD)"
[[ "$(plist SUFeedURL)" == "$FEED" ]] || fail "SUFeedURL is $(plist SUFeedURL), expected $FEED"
# An update signed with any other key would be refused by every installed copy
[[ "$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$(plist SUPublicEDKey)" ]] \
    || fail "SUPublicEDKey in Info.plist is not the public half of the Keychain's $KEY_ACCOUNT key"

# Nested code first, inside-out and without --deep, in the order Sparkle's documentation signs it; then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
SIGN=(codesign -f -s "$DEVELOPER_ID" --options runtime --timestamp)
if [[ -d "$FW/Versions/B/XPCServices" ]]; then
    $SIGN "$FW/Versions/B/XPCServices/Installer.xpc"
    $SIGN --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
fi
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP/Contents/Helpers/sukusho-mcp"; do
    $SIGN "$code"
done
$SIGN --entitlements Screendrop/Screendrop.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
for f in "$APP" "$APP"/Contents/**/*(.ND); do   # every piece of code, so nothing unsigned by us slips in
    [[ "$f" == "$APP" || "$(file -b "$f")" == Mach-O* ]] || continue
    INFO="$(codesign -dv "$f" 2>&1)"
    [[ "$INFO" == *"flags=0x10000(runtime)"* && "$INFO" == *"TeamIdentifier=$TEAM"* && "$INFO" == *Timestamp=* ]] \
        || fail "$f: signature lacks the hardened runtime, Team ID $TEAM or a secure timestamp"
done
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
[[ "$ENTITLEMENTS" == *com.apple.security.device.audio-input* && "$ENTITLEMENTS" == *com.apple.security.device.camera* \
    && "$ENTITLEMENTS" != *get-task-allow* ]] || fail "entitlements must hold audio-input and camera, and no get-task-allow"
EXE="$APP/Contents/MacOS/Sukusho"
(( $(nm "$EXE" | grep -c __profc_ || true) == 0 )) || fail "the executable carries code-coverage counters"
ARCHS="$(lipo -archs "$EXE")"

NOTARY=()
notarize() {   # $1: the file to submit; returns only when Apple's answer is Accepted
    local name="${1:t}" id notary_status
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/$name.notary.json" || true
    id="$(plutil -extract id raw "$OUT/$name.notary.json")"
    notary_status="$(plutil -extract status raw "$OUT/$name.notary.json")"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/$name.notary-log.json" || true
    print -r -- "notarization of $name: $notary_status ($id)"
    [[ "$notary_status" == Accepted ]] || fail "notarization of $name: $notary_status, see $OUT/$name.notary-log.json"
    NOTARY+=("$name $id")
}
gatekeeper() {   # $@: spctl arguments; Gatekeeper must accept the item as notarized Developer ID
    local verdict
    verdict="$(spctl --assess -vvv "$@" 2>&1)" || fail "Gatekeeper rejected: $verdict"
    print -r -- "$verdict"
    [[ "$verdict" == *"source=Notarized Developer ID"* ]] || fail "not accepted as notarized: $verdict"
}

ditto -c -k --keepParent "$APP" "$OUT/Sukusho.zip"
notarize "$OUT/Sukusho.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
gatekeeper --type execute "$APP"

DMG="$OUT/Sukusho-$VERSION.dmg"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Sukusho.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Sukusho $VERSION" -srcfolder "$OUT/dmg" -format UDZO -o "$DMG"
codesign -s "$DEVELOPER_ID" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
gatekeeper --type open --context context:primary-signature "$DMG"

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")

# Sparkle's feed, one item: the stapled DMG's EdDSA signature, the download on GitHub Releases, the notes embedded
mkdir "$OUT/updates"
cp "$DMG" "$OUT/updates/"
cp "$NOTES" "$OUT/updates/Sukusho-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/tommyent/sukusho/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/tommyent/sukusho/releases" \
    --link "https://tommyent.github.io/sukusho/" "$OUT/updates"
APPCAST="$(<"$OUT/updates/appcast.xml")"
for want in "<sparkle:version>$BUILD</sparkle:version>" "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    "url=\"https://github.com/tommyent/sukusho/releases/download/v$VERSION/Sukusho-$VERSION.dmg\"" \
    "length=\"$(stat -f %z "$DMG")\"" "sparkle:edSignature=" 'sparkle:format="markdown"' \
    "<sparkle:minimumSystemVersion>"; do
    [[ "$APPCAST" == *"$want"* ]] || fail "appcast lacks $want"
done

cat > "$OUT/manifest.txt" <<EOF
version: $VERSION ($BUILD)
commit: $(git rev-parse HEAD)
sha256: $(cut -d' ' -f1 "$DMG.sha256")  ${DMG:t}
architectures: $ARCHS
identity: $DEVELOPER_ID
team: $TEAM
notary: ${(j:, :)NOTARY}
appcast: $OUT/updates/appcast.xml (EdDSA key: $KEY_ACCOUNT)
built on: macOS $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' ')SDK $(xcrun --sdk macosx --show-sdk-version), $(uname -m)
EOF
cat "$OUT/manifest.txt"
print "release: $OUT"
