#!/bin/zsh
# The Theme Tuner (ThemeTuning.swift, GlassTuning.swift, ThemeTunerView.swift) is the owner's alone: PERSONAL=1
# scripts/release.sh compiles it in (PERSONAL_CONDITIONS=THEME_TUNER, which sets THEME_TUNER), and a release must never
# carry it. Its defaults keys, C strings in the executable, show whether a build has it: Chip's and Glass's, each
# checked alone, so a build carrying either part fails a release. release.sh runs this on every build.
# Usage: scripts/check-theme-tuner.sh <Sukusho.app> personal|release
set -euo pipefail
APP=${1:?"usage: $0 <Sukusho.app> personal|release"}
[[ ${2:-} == (personal|release) ]] || { print -u2 "usage: $0 <Sukusho.app> personal|release"; exit 64 }
CODE=("$APP"/Contents/MacOS/*(.N))   # the executable, and a Debug build's .debug.dylib, which holds its code
(( ${#CODE} )) || { print -u2 "Theme Tuner check: no executable in $APP"; exit 1 }
TEXT=$(strings -a "${CODE[@]}") || { print -u2 "Theme Tuner check: couldn't read the executable in $APP"; exit 1 }
for KEY in ThemeTunerChipValues ThemeTunerGlassValues; do
    FOUND=$(print -r -- "$TEXT" | grep -c "$KEY" || true)   # -c reads it all: no early exit for pipefail
    case $2 in
        personal) (( FOUND > 0 )) || { print -u2 "Theme Tuner check: $APP has no $KEY; a personal build has the whole tuner"; exit 1 } ;;
        release) (( FOUND == 0 )) || { print -u2 "Theme Tuner check: $APP carries $KEY; a release never may"; exit 1 } ;;
    esac
    print -r -- "Theme Tuner check: $KEY found $FOUND times"
done
print -r -- "Theme Tuner check: passed for a $2 build"
