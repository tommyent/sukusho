// Which NSPasteboard calls raise macOS's "paste from other apps" alert, and
// whether a grant survives a rebuild. Built into a signed .app by build.sh;
// see README.md. Logs JSON lines, never the clipboard's contents.
import AppKit

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SukushoPasteboardProbe.log")
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "safe"            // "safe": no content read; "read": also reads
let expectedSample = arguments.dropFirst().first // what probe-write put on the pasteboard
let runID = UUID().uuidString.prefix(8)

func record(_ step: String, _ fields: [String: Any] = [:]) {
    var line = fields
    line["run"] = String(runID)
    line["step"] = step
    line["at"] = ISO8601DateFormatter().string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
          var text = String(data: data, encoding: .utf8) else { return }
    text += "\n"
    print(text, terminator: "")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: logURL)
    }
}

func name(_ behavior: NSPasteboard.AccessBehavior) -> String {
    switch behavior {
    case .default: "default"
    case .ask: "ask"
    case .alwaysAllow: "alwaysAllow"
    case .alwaysDeny: "alwaysDeny"
    @unknown default: "unknown(\(behavior.rawValue))"
    }
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

@MainActor
func runProbe() async {
    let pasteboard = NSPasteboard.general
    let info = Bundle.main.infoDictionary ?? [:]
    record("start", [
        "mode": mode,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "bundle": Bundle.main.bundleIdentifier ?? "none",
        "build": info["CFBundleVersion"] as? String ?? "?",
    ])
    record("accessBehavior.before", ["value": name(pasteboard.accessBehavior)])

    var start = DispatchTime.now()
    let count = pasteboard.changeCount
    record("changeCount", ["ms": milliseconds(since: start), "value": count])

    start = DispatchTime.now()
    let types = pasteboard.types?.map(\.rawValue) ?? []
    record("types", [
        "ms": milliseconds(since: start),
        "count": types.count,
        "hasProbeSample": types.contains("com.tommyent.Sukusho.probe-sample"),
        "hasTransientMarker": types.contains("org.nspasteboard.TransientType"),
    ])

    start = DispatchTime.now()
    let items = pasteboard.pasteboardItems?.count ?? -1
    record("pasteboardItems.count", ["ms": milliseconds(since: start), "value": items])

    start = DispatchTime.now()
    do {
        let found = try await pasteboard.detectedPatterns(for: [\.probableWebURL, \.number])
        record("detectedPatterns", ["ms": milliseconds(since: start), "found": found.count])
    } catch {
        record("detectedPatterns", ["ms": milliseconds(since: start), "error": "\(error)"])
    }

    if mode == "read" {
        // A read that raises the alert blocks this thread until it is answered;
        // the watchdog ends the run so an unattended Mac isn't left waiting.
        let timeout = 20.0
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            record("read", ["blockedFor": timeout, "outcome": "still blocked, exiting"])
            exit(3)
        }
        start = DispatchTime.now()
        let value = pasteboard.string(forType: .string)
        record("read", [
            "ms": milliseconds(since: start),
            "outcome": value == nil ? "nil" : "string",
            "matchesSample": expectedSample.map { value == $0 } ?? false,
        ])
        record("accessBehavior.after", ["value": name(pasteboard.accessBehavior)])
    }
    record("end")
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await runProbe()
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
