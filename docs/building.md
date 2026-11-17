# Building from source

The Xcode project sets a macOS 26.0 deployment target, so the app opens on macOS 26 too. Anything newer is used behind `#available` checks, and a launch notice on macOS 26 says some features may be missing. To build this source tree, use:

- Xcode 27, with its Metal Toolchain for Studio's motion-blur shader:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- Your Apple Developer team ID, to sign the app.

Build Sukusho with your team ID in place of `YOUR_TEAM_ID`:

```bash
xcodebuild build -project Screendrop.xcodeproj -scheme Screendrop \
  -configuration Release -destination "platform=macOS" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

To tell Debug builds apart, add `SUKUSHO_GIT_COMMIT=$(git rev-parse --short HEAD)` to the command: Settings › About and the copied version line then name the commit, as in “1.2.0 (32, d761462)”. Release builds never show it.

The `Screendrop` scheme builds `Sukusho.app` (`com.tommyent.Sukusho`). The `Screendrop Dev` scheme with the `Debug Dev` configuration builds `Sukusho Dev.app` (`com.tommyent.Sukusho.dev`), which keeps its own data folder and keychain item, apart from Sukusho's. The Xcode target, schemes and Swift module keep the name Screendrop.

Run the test suite:

```bash
xcodebuild test -project Screendrop.xcodeproj -scheme "Screendrop Dev" \
  -configuration "Debug Dev" -destination "platform=macOS" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

The tests use Swift Testing, need no app host, and never touch your captures or settings; see [ScreendropTests/README.md](../ScreendropTests/README.md). Xcode resolves the package dependencies: DockProgress, Sparkle for updates, and the MCP Swift SDK for the agent helper. The image optimizers (oxipng, cwebp, webpmux, cjpeg, jpegtran) are checked in, already built, in `Vendor/optimizers`, and the build copies them into the app; `scripts/build-optimizers.sh` rebuilds them from pinned source with cargo and cmake when a version changes. [Editor performance](editor-performance.md) and [export performance](export-performance.md) describe the standalone checks and benchmarks.

If Screendrop was installed before, Sukusho brings over its captures, recordings, settings and Cloud token once, the first time it opens. Screendrop's own copy is left unchanged.
