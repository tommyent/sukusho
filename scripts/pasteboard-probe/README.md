# Pasteboard access probe

Answers two questions for the clipboard history: which `NSPasteboard` calls raise macOS's "paste from other apps" alert for a background app, and whether a grant survives a rebuild. Rerun it after each macOS update.

```bash
scripts/pasteboard-probe/build.sh <out-dir> [build-number]
cd <out-dir>
open -n -W SukushoPasteboardProbe.app --args safe          # no content read
S=sample-$RANDOM; ./probe-write "$S"                        # another process copies
open -n -W SukushoPasteboardProbe.app --args read "$S"     # times one content read
tail ~/Library/Logs/SukushoPasteboardProbe.log
```

- The app is `com.tommyent.Sukusho.pasteboard-probe`, signed with the Mac's first Developer ID identity, as personal Sukusho builds are.
- `probe-write` keeps its sample on this Mac (`currentHostOnly`) and marks it transient, so clipboard histories skip it. It still replaces what's on the clipboard.
- The log has timings, counts and access states, never clipboard contents.
- A read that raises the alert blocks; the probe gives up after 20 s and logs `still blocked`.
- To test a grant across an update: answer the alert with Always Allow, rebuild with a higher build number, and run `read` again.

## Results

| Date | Mac, macOS | Before | Read | After |
|---|---|---|---|---|
| 2026-11-16 | Mac mini, 27.3 (26C5035r) | `alwaysAllow` | 0.1 ms, sample matched, no alert | `alwaysAllow` |

On 27.3 a never-asked app reports `alwaysAllow` and reads without an alert. Apple's docs say such an app reports `default` while the feature is on, so the alert isn't enforced on this build. With nothing to grant, the update question can't be tested yet.
