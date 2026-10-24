# Logic tests

Scrolling Capture frame dumps are opt-in (`ScrollingCaptureTrace` in the app's defaults) and local only: each capture writes its selection crops as PNGs plus `frames.jsonl` and `page.json` under the app's Caches folder in `Screendrop/ScrollingCaptureFrames`, laid out as a corpus page for `scripts/scroll-corpus-run.swift`. They contain screen content.

Scrolling Capture is tested by its corpus run (`scripts/scroll-corpus-run.swift`, outside the test target) plus three tests on the pure functions in `ScrollingOffsetTests`, which use three 600x400 PNG crops of Wikipedia's "Scroll" article (CC BY-SA 4.0) from the scrolling corpus, in `Fixtures/wikipedia-scroll-*.png`. Never commit frames of private captures.

Run the shared `Screendrop` or `Screendrop Dev` scheme's Test action. On this fork's build Mac:

```sh
xcodebuild test -project Screendrop.xcodeproj -scheme "Screendrop Dev" \
  -configuration "Debug Dev" -destination "platform=macOS" \
  -derivedDataPath /private/tmp/screendrop-dd/wt-fork-logic-tests \
  DEVELOPMENT_TEAM=NMM3956F6W -allowProvisioningUpdates
```

`ScreendropTests` uses Swift Testing with **no app host**. It compiles the actual production files listed under “Tested logic” in the project. There are no copied implementations, generated source adapters, test dependencies or network calls. Tests do not open windows, register shortcuts, capture screens, access cameras or change preferences. AppKit types are used for model geometry and in-memory bitmaps only.

The regular Build action builds the app; the Test action builds the app and runs this suite. Nothing is installed or launched as an app. New test files in `ScreendropTests` are picked up by Xcode's synchronized group. Add production-file memberships to the test target when a new helper is needed.

Fixtures should be generated in memory. Keep any required recorded regression fixture small and local to the test bundle; never depend on an agent's temporary folder or a network URL. Use `#expect`/`#require`, which remain active in optimized builds, instead of `assert` or trapping `precondition`.

`AnnotationClipboardTests` checks annotation clipboard round-trips, new IDs, repeated paste offsets,
unchanged geometry across screenshot sizes, internal arrow bindings, detached terminals and arcs, embedded
pictures, newest-copy replacement and engine Undo/Redo. After a Dev build, run
`python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-annotation-copy-paste.swift`
for the actual editor model's no-selection Copy fallback, annotation/picture routing, selection and
one-step Undo/Redo. Both use disposable named pasteboards. Native keyboard/menu delivery and text-field
Copy/Paste remain for the coordinator's approved live round.

`RecordingDesktopFilterTests` checks the production app/window exclusion rules: ordinary Finder windows and wallpaper stay, only Finder's desktop-icon layer is excluded, and recording cleanup stays independent of the app-window preference. Camera-bubble and recording-pen checks cover both preferences and both clean-desktop modes, including ScreenCaptureKit's inverted window exceptions; the recording bar and ordinary app windows still follow the preference. Actual ScreenCaptureKit pixels, native screenshot hiding/restoration, system-host recreation, area geometry and picker accessibility require the approved live round.

`RecordingInkTests` covers the recording pen's strokes in `input.json`: legacy sidecars without them, the sanitizer carrying them across, the replayed prefix, hold, fade and undo through cuts and speed, and the mapping of live samples onto the movie. After a Dev build, `python3 scripts/check-video-ink.py /path/to/DevDerivedData` compiles the actual app sources into an isolated-home, windowless harness: Studio's model (prefix, delete and Undo, Show drawings, documents that still match older renders) and exported pixels through a 2x zoom and a held screen layer that is captured again mid-stroke, on both screen renderers, plus a deleted stroke left out of Library and share renders. The live pen panel, its capture exclusion and focus need the approved live round.

`RecordingAgentPromptTests` compiles the production input/transcript schemas, clip timeline, prompt planner and folder writer. It checks cuts and speed, corrected versus recognizer text, cue-only and silent recordings, action grouping, Markdown escaping and legacy decoding. Pointer rests and scroll runs become moments through cuts and speed, capped to the longest on long recordings; scroll events coalesce, survive sanitizing and decode from older files. Each moment's strip comes from the master at the moment's position, never enlarged, with the pointer ringed and later frames changing as the movie does. Clicks name their cursor (AppKit's own and the editor's plus are matched by image; others are described by size and hot spot), and the prompt links the screen recording and input log. Shortcuts read by key (⇧⌘3, also for older recordings that saved ⇧⌘#), and the prompt warns only when the recording left out Sukusho's windows. Its disposable red/blue movie checks JPEG pixels, relative links, collision handling, mismatched duration and cancellation cleanup. It does not run speech recognition, the full Studio renderer, Finder or clipboard actions.

`InFlightRendersTests` checks how a render is shared: a second request for the same key waits for the running render and gets its progress; cancelling that joiner only ends its wait; a joiner renders once itself when the shared render fails or its owner is cancelled; another key renders separately.

`RecordingRenderCaptionTests` checks the shared render caption preparation, including corrected wording, ambiguous partial cues and partly cut words. After a Dev build, `python3 scripts/check-recording-export-regressions.py /path/to/DevDerivedData` compiles the actual app sources into a windowless harness. It holds a model export at an async suspension to check cancel/retry, compares plain and karaoke caption pixels from a synthetic cut movie with safe and leaking controls, and checks that pre-fix cached renders re-render. It also opens the Studio model on an unedited package whose render is stamped with no document: flushing and closing Studio must keep that render, while an edited draft or save drops it. Two requests for the same edits while one renders, one through Studio's package URL and one through the after-capture Copy's, must make a single encode. Export Agent Prompt on an unedited, never-saved recording, as the Library runs it with Studio open, must reuse that Stop-time render, which must survive closing Studio; unsaved edits must still reach it. Quick Look's choice of file is checked on synthetic packages: a fresh render or the screen master opens at once, while pending redactions or unreadable edits still render first. A package with an unreadable draft opens Studio on its `edit.json` with export, upload and saving blocked until Discard. Run outside the agent sandbox when AVFoundation reports an unavailable encoder; no app or live services are launched.

Codec checks in the same harness: an HEVC project's upload render, its render stamp and Studio's share render are H.264, while its local export is HEVC and never copies the H.264 share render. The remembered export default moves from H.264 to HEVC once, and later or first-time H.264 choices stick. A recording without saved edits renders Copy and uploads with the remembered choice, as an H.264 movie, matching Studio's share settings; with nothing remembered it stays full size H.264. `UserDefaults` ignores the isolated home, so these checks write only the harness binary's own domain, empty it, and the runner deletes its plist afterwards.

The editor tests port `scripts/check-editor-{snapping,fill,interaction,snapping-interaction,viewport,resources}.swift` and the export-only part of `check-editor-snapping-render.swift`. Geometry, pointer state transitions, undo/redo, presets, viewport transforms, caches and export bitmaps run without a view or window. The old windowless canvas-drawing checks and Vision/movie cancellation integration script stay separate: they aren't pure model tests.

Highlighter checks cover horizontal/vertical locking during drawing and endpoint drags, two endpoint hit targets, body moves, fixed width, Undo/Redo, normal-alpha drawing and sidecar round-trips. Legacy freehand highlighters still decode, render and resize/rotate. After a Dev build, `python3 scripts/check-highlighter.py /path/to/DevDerivedData` compiles the actual app sources into an isolated-home, windowless harness for pen/marker style memory and straight/legacy PNG export over synthetic text. Live endpoint presentation, screenshot-backdrop compositing, text readability, accessibility activation and dock fit remain in the coordinator's approved live round.

Idle saving also has a standalone race harness against the actual app sources, including `AnnotationEditorModel`, the renderer, file transaction and close guard. After a Dev build, pass its DerivedData folder:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData
```

It excludes only `AppEntry.swift`, uses the existing built DockProgress dependency, and verifies Foundation's storage resolves inside a temporary home before creating synthetic captures. It covers crop/undo, image deletion, text/composition and drag gates, coalescing, transaction failure, and close/quit during a delayed render. One AppKit window exercises the close delegate but is never shown or focused. Three 5K background/blur commits provide timings. The runner holds the shared benchmark lock only while executing the checks.

`ColourOpacityTests` checks alpha bounds, hue-only matching, palette alpha copying, sidecar/preset round-trips and legacy opaque swatches. The same full-source runner accepts the focused windowless opacity harness:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-editor-colour-opacity.swift
```

It checks mixed-colour selection across all six swatch-bearing shapes, one-step drag Undo/Redo, style readout restoration, new strokes and remembered alpha. Synthetic text exports through `AnnotationRenderer` check 0%, 35% and 100% pixels. Popover dismissal, keyboard/VoiceOver adjustment, native colour-panel alpha policy and minimum-window layout still require the coordinator's approved live round.

Video redaction also has a windowless harness against the production app sources. It uses generated movies and an isolated temporary home to check mask persistence/undo, invalid-input reporting, preview failure handling, sparse-frame timing, CPU/Metal rendering, movie/GIF pixels, drag transfers, poster freshness and unchanged original bytes. After a Dev build, pass its DerivedData folder:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 scripts/check-video-redaction.py /path/to/DevDerivedData
```

Session snapshot checks cover unedited opens, five-session retention, deduplication, cropped pixels and pasted pictures after restore, Undo/Redo and auto-save in both editors, and Studio soundtrack retention and write failures. Recovery cases include unreadable metadata, failed pruning, error suppression and both saved-open and crash-draft-open sessions during storage failures. Library Trash uses a disposable destination to check that the snapshot folder moves with its capture; no files go to the user's Trash.


`RecordingChapterTests` checks pause proposals, preservation of manual names, cut/speed mapping, source-anchor restoration, opening-sentence bounds, invalid anchors and backward-compatible project metadata. Chapter edits are navigation metadata; they do not change the render document.

Chapter regressions also cover the half-second end margin, automatic names after cuts in both Studio mapping and share data, manual/legacy names, and decoding then dropping retired metadata fields on save. Opening-sentence titles use surviving corrected cues and omit ambiguous partly cut prose. The windowless `check-recording-export-regressions.py` harness also runs the production chapter-field draft/commit logic and Studio model against a disposable package: rename, Return, one Undo and focus loss must preserve "Chapter 1" in the field value, model and `project.json`, with no extra commit. A control without title synchronization reproduces the overwrite; Redo and fresh edits are also checked. Native field event delivery and the "Use Opening Sentence as Title" action remain in the coordinator's approved live round.

Add-at-playhead checks in that harness cover corrected surviving narration after cuts/speed changes, transcript edits until a manual rename, numbered silence fallback before the next chapter, duplicate prevention, legacy numbered names, persistence and Undo/Redo. Hostless chapter tests also check numbered automatic fallbacks in Studio/share data without changing legacy names.

Chapter-marker tests cover current-chapter boundaries and neighbour/end clamping in edited time. The recording harness checks local drag previews, one saved source-anchor move across cuts/speed changes, list updates, paused seeking, one-step Undo/Redo, reopen persistence and invalid/no-op moves. Native marker clicks, drags, tooltips, accessibility adjustment, crown hit priority, label truncation and zoom/scroll remain for the approved live round.

`CaptureLibraryTextTests` checks the Library text index's rules: stale fingerprints and versions, newest-first reading, deletions versus an empty scan, the on-disk store, case- and accent-insensitive search over recognized text, matching paragraphs first, and paragraph grouping (wrapped prose, indented code, columns, stray fragments). Real Vision reading runs in a windowless harness against the actual app sources: `python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-library-text-index.swift` reads a synthetic screenshot and recording (frames plus saved captions), searches them, re-reads an edit, and checks the switch and deletion. It also decodes History rows with and without a source app, and runs `app:` against the real Library model with words, recognized text, tags, kinds and a recording's project metadata. Vision fails in the VMPal VM, so run it on a Mac.

The Library grid's updates run in the same harness: `python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData scripts/check-library-grid-update.swift` hosts the real `CaptureLibraryCollection`, windowless, with probe cards. A title change must redraw its card in place and rebuild none (a rebuild blanks every thumbnail); an insert must still reload.

`CaptureSourceSearchTests` checks the search operator parser (`app:`, quoted values, words around operators, unknown operators and other colons kept as words, half-typed operators), `app:` matching on the app name or the bundle ID's last part, AND with words and other operators, and decoding project metadata with and without a source.

`FreeToUseMusicTests` compiles the production API client, picker model and preview
controller. Saved category/search JSON checks all category pages, ordered artist
and tag pairs, premium filtering, media URL validation, credit text, search query
encoding, start offsets and inline error/retry handling. Controlled URLProtocol
responses exercise late search results/errors, actual download tasks, closing
during a suspended download and synchronous callback copying before cleanup.
Generated audio checks content validation and invalid-body Retry. A silent
AVPlayer stand-in exercises preview state and explicit scrub offsets through
download Retry without starting transport or sound output. Tests never request
live music or open the picker. Audible streaming, native scrubbing/accessibility
activation and the merged Studio receiver remain in the approved live round.

`RecordingBackgroundMusicTests` checks stored defaults/validation, loop fill and start offsets, microphone RMS speech intervals, short-gap bridging, cut/speed mapping, attack/release and the final-second fade. The windowless recording regression harness also imports a synthetic picker download and deletes it immediately, restores saved music after discard, rejects invalid audio, checks legacy decoding and retained files, and compares tone levels in the actual Studio preview composition, shared video and WAV export. It checks music under voice/system audio, source-mic ducking, looping from an offset, independent volume, exact cut duration and compatibility with Replace and Isolate Voice, and Undo order when a volume drag spans an import's adoption. Real voice/music quality, inspector layout, native accessibility activation, clipboard credit copying and picker integration remain for the coordinator's approved live round.

That harness also checks a microphone-only recording with a camera and a generated
44.1 kHz stereo MP3 through Studio's configuration/cache decisions and MP4 720p
export, plus the shared upload renderer. It rejects a GIF intermediate as a movie
cache, preserves music in upload movies while GIF export is selected, retains the
correct movie cache through draft flushing, and keeps container-only reuse.
Set `SCREENDROP_CHECK_MUSIC_DELIVERY_ONLY=1` to run just these delivery checks.
It does not invoke export notifications, Finder, upload transport or live UI.

It also exports white footage and a white camera over a light background and
checks that no straight card or camera edge pixel is darker than the shadowed
background beside it: shadows cast by filling the shape left a dark outline
there. A floor checks that both shadows are still drawn just below each shape.
The harness has no Metal library, so it exercises the Core Graphics
compositor; Metal uses the same backdrop and camera-shadow images.
