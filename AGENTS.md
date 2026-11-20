# AGENTS.md

## Project overview

Screendrop is a native macOS screenshot and screen recording tool. Its Library window opens on normal launch; login launches remain in the menu bar (`LSUIElement = YES`). `AppActivationPolicy` uses `.regular` while Library, Settings, or editor windows are open, and returns to `.accessory` when they close. Built with SwiftUI + AppKit with a hostless Swift Testing unit test target.

**Deployment target:** macOS 26.0 for every target, so the app opens on macOS 26 too (the owner, 2026-11-16). Gate anything newer with `#available(macOS 27, *)` and a fallback, never by raising the target or dropping the feature on 27; below the oldest release in `AppVersion.testedMacOS` a modeless launch notice (`UnsupportedOSNotice`) says some features may be missing. Builds with Xcode 27 (`/Applications/Xcode.app`, 27.2).
**App:** Sukusho. **Bundle IDs:** `com.tommyent.Sukusho`, Dev `com.tommyent.Sukusho.dev`. The target, schemes and Swift module keep the name Screendrop.

## Build

Use `xcodebuild` from the command line, with Xcode 27 and its Metal Toolchain:

```bash
set -o pipefail; xcodebuild build \
  -project Screendrop.xcodeproj -scheme Screendrop -configuration Debug -destination "platform=macOS" \
  2>&1 | tee <scratchpad>/build.log | xcbeautify -q
```

`xcbeautify -q` prints only warnings, errors and the result, `pipefail` keeps xcodebuild's exit code, and the full log stays in `build.log`.

There are two shared schemes for the same target: `Screendrop` runs the Debug configuration, and `Screendrop Dev` runs `Debug Dev` (bundle ID `com.tommyent.Sukusho.dev`). Both run tests in Debug. Use `Screendrop` unless told otherwise.

`ScreendropTests` is wired into both shared schemes. It compiles the selected production logic directly, with no app host, windows, permissions or live services.

```bash
xcodebuild test -project Screendrop.xcodeproj -scheme "Screendrop Dev" \
  -configuration "Debug Dev" -destination "platform=macOS" \
  DEVELOPMENT_TEAM=NMM3956F6W -allowProvisioningUpdates
```

See `ScreendropTests/README.md` for coverage and fixture rules. Run tests before committing.

## Swift concurrency settings

The project uses **strict concurrency** settings that are easy to violate:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - every type is implicitly `@MainActor` unless explicitly opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` - imports in one file do not leak to other files.

When adding new types, assume `@MainActor` isolation by default. If a type must be `Sendable` or `nonisolated`, mark it explicitly.

## Architecture

All source is in `Screendrop/` (flat, except the annotation engine in `Screendrop/Engine/`). Key flow:

1. **App entry** - `ScreendropApp.swift`: `@main` App struct. Creates a `MenuBarExtra`, the Library `Window`, and `WindowGroup`s for the annotation editor and the recording editor. Settings is an AppKit window (`SettingsWindowController`) opened from the app's Settings command.
2. **Hotkeys** - `HotkeyManager.swift`: Registers global Carbon hotkeys at launch via `AppDelegate`. The defaults (⌘⇧1 to ⌘⇧6, one per capture action) are in `CaptureHotkeys.swift`; shortcuts the user recorded replace them.
3. **Capture** - `CaptureCoordinator.swift` → `ScreenshotManager.swift`: Fullscreen, window and area use the `/usr/sbin/screencapture` CLI; Scrolling Capture uses `ScreenCaptureKit`. The area of the Area screenshot and of Capture Text is drawn in Sukusho's own picker (`RecordingAreaSelectionPresenter`, shared with area recording and Scrolling Capture) and then taken with `screencapture -R`: Shift snaps to a box found in a frozen frame's pixels (`SmartAreaDetector`), Option shows a loupe. `defaults write <bundle id> areaCaptureUsesSystemPicker -bool YES` brings back `screencapture -s`.
4. **Preview** - `PreviewPanelPresenter.swift` + `PreviewWindowView.swift`: Borderless floating `NSPanel` showing a screenshot stack. Uses `ScreenshotPreviewStack` (an `@Observable` model).
5. **Annotation** - `AnnotationEditorWindow.swift` + `AnnotationEditorModel.swift` + `AnnotationCanvas.swift`: Full annotation editor; its tools are the cases of `AnnotationTool` (`AnnotationTool.swift`). All coordinates are normalized (0..1) relative to the image.
6. **Rendering** - `AnnotationRenderer.swift`: Composites annotations onto the source image at full pixel resolution using Core Graphics.
7. **Preferences** - `ScreendropPreferences.swift` + `SettingsView.swift`: `UserDefaults`-backed settings (auto-save, auto-copy, auto-compress, export directory).
8. **Library** - `CaptureLibraryView.swift` + `CaptureLibraryModel.swift`: Single native sidebar/detail/inspector scene. `CaptureLibraryCollection.swift` reuses AppKit cells for grid/list layouts; `CaptureLibraryThumbnails.swift` bounds decoded image memory and concurrency. The model merges History metadata with recording packages by standardized package path. Existing capture storage and editable sidecars remain authoritative. `CaptureLibraryActions.swift` handles batch operations and prevents trashing captures while their editors are open.
9. **Themes** - `AppTheme.swift`: Settings › Appearance picks a theme for Light and one for Dark (Classic is beta 5's look, as data). Chrome colours (`Palette`, `WorkspaceChrome`), the workspace ground and Library cards read the theme of their appearance; views use `@CurrentTheme`, AppKit's dynamic colours `AppTheme.current(for:)`. A card's recipe is drawing code (`LibraryCardSurface`); a theme only tunes it. Themes are screen only. `scripts/check-classic-render.sh <Dev DerivedData>` renders Classic's cards and chrome with beta 5's sources and today's and fails on any byte that differs; run it after touching any of them. Chip's paper grain (`PaperGrain.png`, baked by `scripts/make-paper-grain.py` from ambientCG's CC0 Paper006) is held to the caption strip by `scripts/check-chip-paper.sh <Dev DerivedData>`. The Theme Tuner (`ThemeTuning.swift`, `ThemeTunerView.swift`, Sukusho › Theme Tuner…) tunes Chip live and copies its values as `AppTheme.chip`'s lines. It's compiled only with `THEME_TUNER`, which only `PERSONAL=1 scripts/release.sh` sets (`PERSONAL_CONDITIONS=THEME_TUNER`; pass the same to `xcodebuild` for a Dev build with it), and `scripts/check-theme-tuner.sh` fails a release that carries it.

### Singletons

Most managers are `static let shared` singletons: `ScreenshotManager`, `CaptureCoordinator`, `HotkeyManager`, `PreviewPanelPresenter`, `ScreenshotPreviewStack`, `PreviewWindowPlacement`, `PreviewWindowCaptureExclusion`. Follow this pattern for new services.

### Annotation coordinate system

All annotation positions/sizes are normalized to `[0, 1]` relative to the source image dimensions. Pixel conversion happens only in `AnnotationRenderer` at export time and in the canvas view for display. Do not use pixel coordinates in the model layer.

## Conventions

- **No new SPM packages or external dependencies** without the owner's OK. The existing ones are DockProgress, Sparkle (updates) and the MCP Swift SDK (the `sukusho-mcp` helper only); otherwise the project uses only Apple frameworks (SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, CoreImage, ImageIO, Carbon).
- **Image optimizers:** `Vendor/optimizers` holds five encoders that the app bundles in `Contents/Helpers` and runs as separate processes through `ImageOptimizer.swift`: oxipng (MIT), libwebp's cwebp and webpmux (BSD-3-Clause), and MozJPEG's cjpeg and jpegtran (IJG, BSD-3-Clause, zlib). Their licenses are in `Vendor/optimizers/OptimizerLicenses`, shown from Settings › About. `scripts/build-optimizers.sh` builds them from pinned source; the app build only copies and signs what is checked in. Never add a GPL encoder (pngquant, libimagequant, jpegoptim, or anything taken from Clop).
- **`@Observable` macro** (Observation framework) is used for state - not `ObservableObject`/`@Published`.
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) - the app needs screen capture permissions and direct filesystem access.
- Screenshots are saved as lossless PNG to `NSTemporaryDirectory()` first, then optionally compressed to JPEG on export.

## Releases

`scripts/release.sh` builds a release from a clean commit: Developer ID signing with the hardened runtime, a notarized and stapled app inside a notarized and stapled DMG, its checksum, and Sparkle's `appcast.xml`, in a new `../builds/release-<version>.*` folder. It stops at the first check that fails. It needs the release notes in `docs/releases/<MARKETING_VERSION>.md`, the notarytool profile `notary`, and the Sparkle key in the login Keychain (account `com.tommyent.Sukusho`), whose public half is `SUPublicEDKey` in `Info.plist`. A lost key means installed copies refuse every later update. Build numbers are `32.YYMMDD.HHMM` in UTC, because Sparkle compares them and they must only grow. The DMG goes on GitHub Releases and the appcast on the `gh-pages` branch (`scripts/site.sh`), which serves https://tommyent.github.io/sukusho/.

### Releasing a beta

A beta is a release only copies with **Settings › About › Get beta updates** on are offered. Sparkle does this with channels: an appcast item marked `<sparkle:channel>beta</sparkle:channel>` reaches only updaters that allow "beta" (`UpdateChannels`), and items without a channel reach everyone, so a copy on the beta channel still gets every stable release.

1. Set `MARKETING_VERSION` to the version the beta leads to (1.3.0) and write its notes in `docs/releases/1.3.0-beta.1.md`.
2. `BETA=1 scripts/release.sh` (`BETA=2` for the next). The app shows "1.3.0 beta 1"; the DMG, notes and tag are named `1.3.0-beta.1`. Sparkle orders releases by build number, so the name plays no part in which is newer. The script adds the beta's item to the feed on the local `gh-pages` branch, through `scripts/appcast.sh`, and stops unless that item is on the beta channel, every published item is still there, and at least one stable item remains.
3. Put the DMG on GitHub as a draft pre-release, so it never becomes "Latest": `gh release create v1.3.0-beta.1 -R tommyent/sukusho --draft --prerelease --title "Sukusho 1.3.0 beta 1" --notes-file docs/releases/1.3.0-beta.1.md <the DMG> <its .sha256>`. Always pass `-R tommyent/sukusho`: this checkout's `gh` default is the upstream repo it was forked from. Download the draft's own files (`gh release download v1.3.0-beta.1 -R tommyent/sukusho`), install and launch them on a clean Mac, and try what changed. Before publishing, the commit the DMG was built from must be on GitHub and be the draft's target (`gh release edit v1.3.0-beta.1 -R tommyent/sukusho --target <that commit>`), because publishing creates the tag there; then publish with `gh release edit v1.3.0-beta.1 -R tommyent/sukusho --draft=false`.
4. `scripts/site.sh <the release folder>` commits only the appcast for a beta. The page keeps the stable download and doesn't mention the beta. Push `gh-pages` once the GitHub release is published, since the appcast points beta copies at its DMG.

The stable release that follows (`scripts/release.sh` without `BETA`) writes a feed with that release alone, which every copy takes, beta or not. `scripts/check-appcast.sh <Sparkle's bin folder>` dry-runs both kinds of feed with a stand-in app and a throwaway key, without the Keychain or a release.

## Commits

Make atomic commits. Each commit should represent exactly one logical change (e.g. one feature, one bug fix, one refactor). Do not bundle unrelated changes into a single commit. If a task touches multiple concerns, split it into separate commits. Verify the build passes before committing.

## Entitlements / permissions

- Screen recording permission (`NSScreenCaptureUsageDescription` in Info.plist) is required.
- Hardened runtime is enabled.
- No App Sandbox - do not add sandbox entitlements.
