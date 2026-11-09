#!/bin/zsh
# Puts a finished release on the site: commits its appcast.xml and the page's version, download links and DMG size
# to the local gh-pages branch in one commit, without checking the branch out. Pushing it is a separate step, after
# the release is published, since the appcast points every installed copy at the new DMG.
# Usage: scripts/site.sh ../builds/release-<version>.XXXXXX (the folder release.sh printed)
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { print -u2 -- "site: $1"; exit 1 }
REL="${1:?usage: scripts/site.sh <the release folder release.sh printed>}"
VERSION="$(sed -n 's/^version: \([0-9.]*\) .*/\1/p' "$REL/manifest.txt")"
DMG="$REL/Sukusho-$VERSION.dmg"
[[ -n "$VERSION" && -s "$REL/updates/appcast.xml" && -s "$DMG" ]] || fail "$REL is not a finished release"
git rev-parse -q --verify gh-pages >/dev/null || fail "there is no local gh-pages branch"
SIZE="$(printf '%.1f MB' $(( $(stat -f %z "$DMG") / 1000000.0 )))"   # decimal megabytes, as Finder counts

WORK="$(mktemp -d)"
git show gh-pages:index.html > "$WORK/index.html"
# The page names the version only as v1.2.0 (links), Sukusho-1.2.0 (the DMG), "Version 1.2.0" and "Sukusho 1.2.0"
sed -E -i '' -e "s/v[0-9]+\.[0-9]+\.[0-9]+/v$VERSION/g" -e "s/Sukusho-[0-9]+\.[0-9]+\.[0-9]+/Sukusho-$VERSION/g" \
    -e "s/(Version|Sukusho) [0-9]+\.[0-9]+\.[0-9]+/\1 $VERSION/g" -e "s/[0-9]+\.[0-9] MB/$SIZE/g" "$WORK/index.html"
STALE="$(grep -oE '(v|Sukusho-|Version |Sukusho )[0-9]+\.[0-9]+\.[0-9]+' "$WORK/index.html" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u | grep -vxF "$VERSION" || true)"   # other versions, such as the Worker's, are left alone
[[ -z "$STALE" ]] || fail "the page still names another version ($STALE); fix it on gh-pages first"

export GIT_INDEX_FILE="$WORK/index"   # a private index, so the checked-out branch is never touched
git read-tree gh-pages
git update-index --add --cacheinfo "100644,$(git hash-object -w "$WORK/index.html"),index.html"
git update-index --add --cacheinfo "100644,$(git hash-object -w "$REL/updates/appcast.xml"),appcast.xml"
COMMIT="$(git commit-tree "$(git write-tree)" -p gh-pages -m "Sukusho $VERSION: appcast, download links and size")"
unset GIT_INDEX_FILE
git update-ref refs/heads/gh-pages "$COMMIT"
git log -1 --stat gh-pages
