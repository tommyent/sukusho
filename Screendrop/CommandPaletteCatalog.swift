//
//  CommandPaletteCatalog.swift
//  Screendrop
//
//  The command palette's commands as data: each one's name, group, symbol, keys, where it can run and the step it
//  opens. What a command does, whether it can run now and why not are the app's (`CommandPaletteActions.swift`), so
//  this list can be trimmed, reordered or customized without touching them. The tests compile this file.
//

import CoreGraphics
import Foundation

/// The Sukusho window the palette opened over.
nonisolated enum PaletteWindow: Sendable, Hashable {
    case library, editor, studio
    /// A window without commands of its own, such as Settings.
    case other
}

/// Where a command can run.
nonisolated enum PaletteScope: Sendable, Equatable {
    /// In any Sukusho window.
    case anywhere
    /// Only while one of these windows is in front.
    case windows(Set<PaletteWindow>)

    static func only(_ window: PaletteWindow) -> PaletteScope { .windows([window]) }

    func isListed(in window: PaletteWindow) -> Bool {
        switch self {
        case .anywhere: true
        case .windows(let windows): windows.contains(window)
        }
    }

    /// Commands of the window in front rank ahead of the ones that run in any window.
    var isWindowsOwn: Bool { if case .windows = self { true } else { false } }
}

/// A heading in the first list, in this order.
nonisolated enum PaletteGroup: Int, Sendable, CaseIterable, Comparable {
    /// `view` is the window's own: the Library's sort, cards and sidebar, and every window's inspector.
    case capture, selection, editor, studio, view, open, look, switches, sukusho

    /// The selection's heading is the selection's own name, from the app.
    var title: String {
        switch self {
        case .capture: "Capture"
        case .selection: "Selection"
        case .view: "View"
        case .editor: "Editor"
        case .studio: "Studio"
        case .open: "Open"
        case .look: "Look"
        case .switches: "Switches"
        case .sukusho: "Sukusho"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A step a row with › opens inside the palette. `commands` is the first list.
nonisolated enum PaletteStep: String, Sendable, Hashable, CaseIterable {
    case commands
    case recentCaptures, recordings, clipboardHistory, goTo, searchCaptures, goToSettings
    case addTag, sortBy
    case revertTo, styles
    case changeTheme, appearance, background

    var placeholder: String {
        switch self {
        case .commands: "Search commands…"
        case .recentCaptures: "Search captures…"
        case .recordings: "Search recordings…"
        case .clipboardHistory: "Search clips…"
        case .goTo: "Go to…"
        case .searchCaptures: "Search your captures for…"
        case .goToSettings: "Search settings…"
        case .addTag: "Search or add a tag…"
        case .sortBy: "Sort by…"
        case .revertTo: "Revert to…"
        case .styles: "Search styles…"
        case .changeTheme: "Search themes…"
        case .appearance: "Light or dark…"
        case .background: "Search backgrounds…"
        }
    }

    /// The field is the answer here, not a filter: the rows follow what's typed.
    var takesText: Bool { self == .searchCaptures || self == .addTag }

    /// The app narrows these rows itself: the typed name, or the ⌃⌘V popup's own search for Clipboard History.
    var appNarrows: Bool { takesText || self == .clipboardHistory }

    /// ↩ on one of its rows leaves the palette open, for the next.
    var staysOpen: Bool { self == .addTag }

    /// Typing at the first list also finds this step's rows, as "Go to Received": its pages are what people look for.
    var titlePrefixInFirstList: String? {
        switch self {
        case .goTo: "Go to"
        case .goToSettings: "Settings ›"
        default: nil
        }
    }
}

/// A command's keys, drawn one keycap per key.
nonisolated enum PaletteKeys: Sendable, Equatable {
    case none
    case keys([String])
    /// The shortcut Settings › Shortcuts holds for it on this Mac.
    case hotkey(CaptureHotkeyAction)
}

nonisolated struct PaletteCommand: Identifiable, Sendable, Equatable {
    /// Stable across releases: a later customization keys on it.
    let id: String
    var title: String
    var group: PaletteGroup
    var symbol: String?
    var scope: PaletteScope
    var keys: PaletteKeys = .none
    /// The step it opens, for a row with ›.
    var step: PaletteStep?
    /// A switch flips without closing the palette and shows its state in color.
    var isSwitch = false
    var isBeta = false

    init(_ id: String, _ title: String, _ group: PaletteGroup, symbol: String? = nil, scope: PaletteScope,
         keys: PaletteKeys = .none, step: PaletteStep? = nil, isSwitch: Bool = false, isBeta: Bool = false) {
        self.id = id
        self.title = title
        self.group = group
        self.symbol = symbol
        self.scope = scope
        self.keys = keys
        self.step = step
        self.isSwitch = isSwitch
        self.isBeta = isBeta
    }
}

// MARK: - The catalog

nonisolated extension PaletteCommand {
    private static let library = PaletteScope.only(.library)
    private static let editor = PaletteScope.only(.editor)
    private static let studio = PaletteScope.only(.studio)

    private static func k(_ keys: String...) -> PaletteKeys { .keys(keys) }

    /// commands.md (sd-458l, 2026-11-24), as the owner left it, less the rows whose actions need a selected row on a
    /// Cloud or Clipboard page (left out there too), Find Sensitive Text… and Show Bug Report in Finder, and the Studio
    /// playback keys, which can't be pressed while the palette has the keyboard.
    static let catalog: [PaletteCommand] = [
        // Capture
        .init("capture.fullscreen", "Capture Fullscreen", .capture, symbol: "macwindow", scope: .anywhere, keys: .hotkey(.fullscreen)),
        .init("capture.window", "Capture Window", .capture, symbol: "macwindow.on.rectangle", scope: .anywhere, keys: .hotkey(.window)),
        .init("capture.area", "Capture Area", .capture, symbol: "rectangle.dashed", scope: .anywhere, keys: .hotkey(.area)),
        .init("capture.scrolling", "Scrolling Capture", .capture, symbol: "rectangle.expand.vertical", scope: .anywhere,
              keys: .hotkey(.scrollingCapture), isBeta: true),
        .init("capture.record", "Record Screen", .capture, symbol: "record.circle", scope: .anywhere, keys: .hotkey(.screenRecording)),
        .init("capture.text", "Capture Text", .capture, symbol: "text.viewfinder", scope: .anywhere, keys: .hotkey(.textCapture)),
        .init("capture.draw", "Draw While Recording", .capture, symbol: "pencil.tip", scope: .anywhere, keys: .hotkey(.drawing)),

        // The Library's selection
        .init("selection.quickLook", "Quick Look", .selection, symbol: "eye", scope: library, keys: k("Space")),
        .init("selection.edit", "Edit", .selection, symbol: "pencil", scope: library),
        .init("selection.rename", "Rename", .selection, symbol: "character.cursor.ibeam", scope: library, keys: k("↩")),
        .init("selection.copy", "Copy", .selection, symbol: "doc.on.doc", scope: library, keys: k("⌘", "C")),
        .init("selection.copyOriginal", "Copy Original", .selection, symbol: "doc.on.doc", scope: library, keys: k("⇧", "⌘", "C")),
        .init("selection.copyText", "Copy Text", .selection, symbol: "text.quote", scope: library),
        .init("selection.export", "Export…", .selection, symbol: "square.and.arrow.down", scope: library),
        .init("selection.share", "Share…", .selection, symbol: "square.and.arrow.up", scope: library),
        .init("selection.reveal", "Reveal in Finder", .selection, symbol: "folder", scope: library),
        .init("selection.revert", "Revert to Original…", .selection, symbol: "arrow.uturn.backward", scope: library),
        .init("selection.optimize", "Optimize", .selection, symbol: "arrow.down.right.and.arrow.up.left", scope: library),
        .init("selection.webp", "Convert to WebP…", .selection, symbol: "photo", scope: library),
        .init("selection.jpeg", "Convert to JPEG…", .selection, symbol: "photo", scope: library),
        .init("selection.gif", "Export as GIF…", .selection, symbol: "photo.stack", scope: library),
        .init("selection.bugReport", "Export Bug Report", .selection, symbol: "ladybug", scope: library),
        .init("selection.guide", "Export How-To Guide", .selection, symbol: "list.number", scope: library),
        .init("selection.shareCloud", "Share to Cloud…", .selection, symbol: "icloud.and.arrow.up", scope: library),
        .init("selection.copyLink", "Copy Cloud Link", .selection, symbol: "link", scope: library),
        .init("selection.openShared", "Open Shared Capture", .selection, symbol: "safari", scope: library),
        .init("selection.deleteCloud", "Delete from Cloud…", .selection, symbol: "icloud.slash", scope: library),
        .init("selection.addTag", "Add Tag", .selection, symbol: "tag", scope: library, step: .addTag),
        .init("selection.trash", "Move to Trash", .selection, symbol: "trash", scope: library, keys: k("⌫")),

        // The window: the Library's own, and every window's inspector
        .init("library.sortBy", "Sort By", .view, symbol: "arrow.up.arrow.down", scope: library, step: .sortBy),
        .init("library.refresh", "Refresh", .view, symbol: "arrow.clockwise", scope: library, keys: k("⌘", "R")),
        .init("library.find", "Find", .view, symbol: "magnifyingglass", scope: library, keys: k("⌘", "F")),
        .init("library.biggerCards", "Bigger Cards", .view, symbol: "plus.magnifyingglass", scope: library, keys: k("⌘", "+")),
        .init("library.smallerCards", "Smaller Cards", .view, symbol: "minus.magnifyingglass", scope: library, keys: k("⌘", "−")),
        .init("library.sidebar", "Hide Sidebar", .view, symbol: "sidebar.left", scope: library, keys: k("⌃", "⌘", "S")),
        .init("window.inspector", "Hide Inspector", .view, symbol: "sidebar.right", scope: .windows([.library, .editor, .studio]),
              keys: k("⌥", "⌘", "I")),

        // The image editor
        .init("tool.select", "Select", .editor, symbol: "cursorarrow", scope: editor),
        .init("tool.rectangle", "Rectangle", .editor, symbol: "rectangle", scope: editor, keys: k("R")),
        .init("tool.ellipse", "Circle", .editor, symbol: "circle", scope: editor, keys: k("O")),
        .init("tool.highlight", "Spotlight", .editor, symbol: "square.dashed.inset.filled", scope: editor),
        .init("tool.arrow", "Arrow", .editor, symbol: "arrow.up.right", scope: editor, keys: k("A")),
        .init("tool.line", "Straight Line", .editor, symbol: "line.diagonal", scope: editor, keys: k("L")),
        .init("tool.freehand", "Freehand", .editor, symbol: "scribble", scope: editor),
        .init("tool.highlighter", "Highlighter", .editor, symbol: "highlighter", scope: editor),
        .init("tool.text", "Text", .editor, symbol: "textformat", scope: editor, keys: k("T")),
        .init("tool.numberedCircle", "Numbered Circle", .editor, symbol: "1.circle.fill", scope: editor, keys: k("N")),
        .init("tool.magnifier", "Magnifier", .editor, symbol: "plus.magnifyingglass", scope: editor, keys: k("M")),
        .init("tool.pixelate", "Pixelate", .editor, symbol: "app.background.dotted", scope: editor, keys: k("P")),
        .init("tool.blur", "Blur", .editor, symbol: "drop.fill", scope: editor, keys: k("B")),
        .init("editor.crop", "Crop", .editor, symbol: "crop", scope: editor, keys: k("C")),
        .init("editor.pickColor", "Pick Color", .editor, symbol: "eyedropper", scope: editor),
        .init("editor.measure", "Measure", .editor, symbol: "ruler", scope: editor),
        .init("editor.biggerText", "Bigger Text", .editor, symbol: "textformat.size.larger", scope: editor, keys: k("⌥", "⌘", "+")),
        .init("editor.smallerText", "Smaller Text", .editor, symbol: "textformat.size.smaller", scope: editor, keys: k("⌥", "⌘", "−")),
        .init("editor.zoomIn", "Zoom In", .editor, symbol: "plus.magnifyingglass", scope: editor, keys: k("⌘", "+")),
        .init("editor.zoomOut", "Zoom Out", .editor, symbol: "minus.magnifyingglass", scope: editor, keys: k("⌘", "−")),
        .init("editor.actualSize", "Actual Size", .editor, symbol: "1.magnifyingglass", scope: editor, keys: k("⌘", "0")),
        .init("editor.zoomToFit", "Zoom to Fit", .editor, symbol: "arrow.up.left.and.arrow.down.right", scope: editor, keys: k("⌘", "1")),
        .init("editor.save", "Save", .editor, symbol: "square.and.arrow.down", scope: editor, keys: k("⌘", "S")),
        .init("editor.saveAs", "Save As…", .editor, symbol: "square.and.arrow.down.on.square", scope: editor, keys: k("⇧", "⌘", "S")),
        .init("editor.revertTo", "Revert To", .editor, symbol: "clock.arrow.circlepath", scope: editor, step: .revertTo),
        .init("editor.upload", "Upload", .editor, symbol: "icloud.and.arrow.up", scope: editor),
        .init("editor.styles", "Styles", .editor, symbol: "paintbrush", scope: editor, step: .styles),

        // Studio
        .init("studio.insertClip", "Insert Video Clip…", .studio, symbol: "film.stack", scope: studio),
        .init("studio.split", "Split at Playhead", .studio, symbol: "scissors", scope: studio, keys: k("⌘", "B")),
        .init("studio.markIn", "Mark In", .studio, symbol: "chevron.left.to.line", scope: studio, keys: k("I")),
        .init("studio.markOut", "Mark Out", .studio, symbol: "chevron.right.to.line", scope: studio, keys: k("O")),
        .init("studio.deleteRange", "Delete Marked Range", .studio, symbol: "delete.left", scope: studio),
        .init("studio.clearRange", "Clear Marked Range", .studio, symbol: "xmark", scope: studio, keys: k("⌥", "X")),
        .init("studio.clipEarlier", "Move Clip Earlier", .studio, symbol: "arrow.left", scope: studio),
        .init("studio.clipLater", "Move Clip Later", .studio, symbol: "arrow.right", scope: studio),
        .init("studio.marker", "Add or Remove Marker", .studio, symbol: "bookmark", scope: studio, keys: k("M")),
        .init("studio.snapping", "Snapping", .studio, symbol: "dot.squareshape.split.2x2", scope: studio, keys: k("N"), isSwitch: true),
        .init("studio.addZoom", "Add Zoom at Playhead", .studio, symbol: "plus.magnifyingglass", scope: studio),
        .init("studio.autoZoom", "Auto Zoom", .studio, symbol: "pointer.arrow.rays", scope: studio),
        .init("studio.addText", "Add Text at Playhead", .studio, symbol: "textformat", scope: studio),
        .init("studio.blur", "Blur at Playhead", .studio, symbol: "drop.halffull", scope: studio),
        .init("studio.pixelate", "Pixelate at Playhead", .studio, symbol: "squareshape.split.3x3", scope: studio),
        .init("studio.videoOverlay", "Add Video Overlay…", .studio, symbol: "pip.fill", scope: studio),
        .init("studio.detachAudio", "Detach Audio", .studio, symbol: "waveform.badge.minus", scope: studio),
        .init("studio.resetClips", "Reset All Clip Edits…", .studio, symbol: "arrow.counterclockwise", scope: studio),
        .init("studio.isolateVoice", "Isolate Voice", .studio, symbol: "waveform.and.mic", scope: studio, isSwitch: true),
        .init("studio.transcribe", "Transcribe Narration", .studio, symbol: "waveform", scope: studio),
        .init("studio.summarize", "Summarize", .studio, symbol: "text.append", scope: studio),
        .init("studio.suggestChapters", "Suggest Chapters", .studio, symbol: "list.bullet.rectangle", scope: studio),
        .init("studio.nameChapters", "Name Chapters", .studio, symbol: "character.textbox", scope: studio),
        .init("studio.removeFillers", "Remove Filler Words", .studio, symbol: "text.badge.minus", scope: studio),
        .init("studio.shortenPauses", "Shorten Pauses", .studio, symbol: "pause", scope: studio),
        .init("studio.translate", "Translate Captions…", .studio, symbol: "translate", scope: studio),
        .init("studio.timelineZoomIn", "Zoom In", .studio, symbol: "plus.magnifyingglass", scope: studio, keys: k("⌘", "=")),
        .init("studio.timelineZoomOut", "Zoom Out", .studio, symbol: "minus.magnifyingglass", scope: studio, keys: k("⌘", "−")),
        .init("studio.fitTimeline", "Fit Timeline", .studio, symbol: "arrow.left.and.right", scope: studio, keys: k("⌘", "0")),
        .init("studio.save", "Save", .studio, symbol: "square.and.arrow.down", scope: studio, keys: k("⌘", "S")),
        .init("studio.export", "Export…", .studio, symbol: "arrow.down.circle", scope: studio),
        .init("studio.upload", "Upload", .studio, symbol: "icloud.and.arrow.up", scope: studio),
        .init("studio.bugReport", "Export Bug Report", .studio, symbol: "ladybug", scope: studio),
        .init("studio.guide", "Export How-To Guide", .studio, symbol: "list.number", scope: studio),
        .init("studio.revertTo", "Revert To", .studio, symbol: "clock.arrow.circlepath", scope: studio, step: .revertTo),
        .init("studio.goToStart", "Go to Start", .studio, symbol: "backward.end", scope: studio, keys: k("Home")),
        .init("studio.goToEnd", "Go to End", .studio, symbol: "forward.end", scope: studio, keys: k("End")),

        // Open
        .init("open.recent", "Recent Captures", .open, symbol: "clock.arrow.circlepath", scope: .anywhere, step: .recentCaptures),
        .init("open.recordings", "Recordings", .open, symbol: "film.stack", scope: .anywhere, step: .recordings),
        .init("open.clipboardStep", "Clipboard History", .open, symbol: "list.clipboard", scope: .anywhere, step: .clipboardHistory),
        .init("open.library", "Show Library", .open, symbol: "square.grid.2x2", scope: .anywhere, keys: .hotkey(.library)),
        .init("open.goTo", "Go to", .open, symbol: "sidebar.left", scope: .anywhere, step: .goTo),
        .init("open.search", "Search Captures…", .open, symbol: "magnifyingglass", scope: .anywhere, step: .searchCaptures),
        .init("open.clipboardPopup", "Clipboard History Popup", .open, symbol: "list.clipboard", scope: .anywhere,
              keys: .hotkey(.clipboardHistory)),
        .init("open.saveFolder", "Open Save Folder", .open, symbol: "folder", scope: .anywhere),

        // Look
        .init("look.theme", "Change Theme", .look, symbol: "paintpalette", scope: .anywhere, step: .changeTheme),
        .init("look.appearance", "Appearance", .look, symbol: "circle.lefthalf.filled", scope: .anywhere, step: .appearance),
        .init("look.background", "Background", .look, symbol: "photo.on.rectangle", scope: .anywhere, step: .background),

        // Switches
        .init("switch.optimizeNew", "Optimize New Captures", .switches, symbol: "wand.and.stars", scope: .anywhere, isSwitch: true),
        .init("switch.optimizeCopy", "Optimize When Copying", .switches, symbol: "doc.on.clipboard", scope: .anywhere, isSwitch: true),
        .init("switch.cleanDesktop", "Clean Desktop", .switches, symbol: "menubar.dock.rectangle", scope: .anywhere, isSwitch: true),
        .init("switch.sounds", "Play Sounds", .switches, symbol: "speaker.wave.2", scope: .anywhere, isSwitch: true),
        .init("switch.menuBarIcon", "Show Menu Bar Icon", .switches, symbol: "menubar.rectangle", scope: .anywhere, isSwitch: true),
        .init("switch.launchAtLogin", "Launch at Login", .switches, symbol: "power", scope: .anywhere, isSwitch: true),
        .init("switch.betaUpdates", "Get Beta Updates", .switches, symbol: "testtube.2", scope: .anywhere, isSwitch: true),

        // Sukusho
        .init("app.settings", "Settings…", .sukusho, symbol: "gearshape", scope: .anywhere, keys: k("⌘", ",")),
        .init("app.goToSettings", "Go to Settings", .sukusho, symbol: "gearshape.2", scope: .anywhere, step: .goToSettings),
        .init("app.checkUpdates", "Check for Updates…", .sukusho, symbol: "arrow.down.circle", scope: .anywhere),
        .init("app.about", "About Sukusho", .sukusho, symbol: "info.circle", scope: .anywhere),
        .init("app.quit", "Quit Sukusho", .sukusho, symbol: "power", scope: .anywhere, keys: k("⌘", "Q")),
    ]
}

// MARK: - Matching

/// How well typed letters match a title, and which letters did, for the Highlighter's swipe. Better tiers first:
/// the title starts with it, a word does, it's inside a word, or the words' initials ("cf" for Capture Fullscreen).
/// Every typed word must match on its own, as in Hashbrown; the worst word sets the tier. Letters merely in order don't
/// count: "rec" found Numbered Circle that way (render, 2026-11-24).
nonisolated struct PaletteMatch: Sendable, Equatable {
    enum Tier: Int, Sendable, Comparable {
        case prefix, wordStart, inside, initials
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var tier: Tier
    /// Character offsets in the title, merged and in order.
    var ranges: [Range<Int>]

    static func match(_ query: String, in title: String) -> PaletteMatch? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array(String($0)) }
        guard !words.isEmpty else { return PaletteMatch(tier: .prefix, ranges: []) }
        let text = Array(title.lowercased())
        // Lowercasing can change a title's length (rare); then the marks would land on the wrong letters.
        guard text.count == title.count else { return nil }
        var worst = Tier.prefix
        var marks: [Range<Int>] = []
        for word in words {
            guard let found = matchWord(word, in: text) else { return nil }
            worst = max(worst, found.tier)
            marks += found.ranges
        }
        return PaletteMatch(tier: worst, ranges: merged(marks))
    }

    private static func wordStarts(_ text: [Character]) -> [Int] {
        text.indices.filter { $0 == 0 || !(text[$0 - 1].isLetter || text[$0 - 1].isNumber) && (text[$0].isLetter || text[$0].isNumber) }
    }

    private static func matchWord(_ word: [Character], in text: [Character]) -> (tier: Tier, ranges: [Range<Int>])? {
        func occurs(at start: Int) -> Bool {
            start + word.count <= text.count && Array(text[start ..< start + word.count]) == word
        }
        if occurs(at: 0) { return (.prefix, [0 ..< word.count]) }
        let starts = wordStarts(text)
        if let start = starts.first(where: occurs) { return (.wordStart, [start ..< start + word.count]) }
        if word.count <= text.count, let start = (0 ... text.count - word.count).first(where: occurs) {
            return (.inside, [start ..< start + word.count])
        }
        let initials = starts.map { text[$0] }
        if word.count > 1, let first = (0 ..< max(0, initials.count - word.count + 1)).first(where: {
            Array(initials[$0 ..< $0 + word.count]) == word
        }) {
            return (.initials, starts[first ..< first + word.count].map { $0 ..< $0 + 1 })
        }
        return nil
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
    }
}

// MARK: - Contrast

/// The system accent made dark enough for white text on it at 4.5:1, as body text needs: the default blue gives
/// 4.0:1 in light and 3.6:1 in dark (Fable's measure, sd-458l). A deep enough accent comes back as it is.
nonisolated enum PaletteAccent {
    struct RGB: Sendable, Equatable {
        var red: Double, green: Double, blue: Double
    }

    /// How strong white words are on the selected row's fill, every one of them: titles, details, reasons, On and
    /// Off and keycaps. The lift leaves opaque white just over 4.5:1 on a yellow accent, so anything less falls short.
    static let textOnFill = 1.0
    /// A keycap's backing on the fill, under its white letter: none, which a 5 % white backing took below 4.5:1.
    static let keycapBackingOnFill = 0.0

    /// White at `opacity` over `color`, as it's drawn.
    static func white(_ opacity: Double, over color: RGB) -> RGB {
        RGB(red: opacity + (1 - opacity) * color.red, green: opacity + (1 - opacity) * color.green,
            blue: opacity + (1 - opacity) * color.blue)
    }

    static func liftedForWhiteText(_ color: RGB, ratio: Double = 4.5) -> RGB {
        var color = color
        // Mixing toward black a little at a time keeps the hue; 40 steps reach black.
        for _ in 0 ..< 40 where contrast(color, with: RGB(red: 1, green: 1, blue: 1)) < ratio {
            color = RGB(red: color.red * 0.95, green: color.green * 0.95, blue: color.blue * 0.95)
        }
        return color
    }

    static func contrast(_ a: RGB, with b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }
}
