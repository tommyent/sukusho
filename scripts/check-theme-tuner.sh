#!/bin/zsh
# The Theme Tuner (ThemeTuning.swift, ThemeTunerView.swift) is the owner's alone: PERSONAL=1 scripts/release.sh
# compiles it in (PERSONAL_CONDITIONS=THEME_TUNER, which sets THEME_TUNER), and a release must never carry it. Its
# defaults key, a C string in the executable, shows whether a build has it. release.sh runs this on every build.
# Usage: scripts/check-theme-tuner.sh <Sukusho.app> personal|release
set -euo pipefail
APP=${1:?"usage: $0 <Sukusho.app> personal|release"}
CODE=("$APP"/Contents/MacOS/*(.N))   # the executable, and a Debug build's .debug.dylib, which holds its code
(( ${#CODE} )) || { print -u2 "Theme Tuner check: no executable in $APP"; exit 1 }
FOUND=$(strings -a "${CODE[@]}" | grep -c ThemeTunerChipValues || true)   # -c reads it all: no early exit for pipefail
case ${2:-} in
    personal) (( FOUND > 0 )) || { print -u2 "Theme Tuner check: $APP has no Theme Tuner; a personal build has it"; exit 1 } ;;
    release) (( FOUND == 0 )) || { print -u2 "Theme Tuner check: $APP carries the Theme Tuner; a release never may"; exit 1 } ;;
    *) print -u2 "usage: $0 <Sukusho.app> personal|release"; exit 64 ;;
esac
print -r -- "Theme Tuner check: passed for a $2 build (tuner key found $FOUND times)"
