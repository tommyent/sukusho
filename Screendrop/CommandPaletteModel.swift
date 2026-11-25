//
//  CommandPaletteModel.swift
//  Screendrop
//
//  The command palette (⇧⌘P in Sukusho's windows, recordable in Settings › Shortcuts), the Rex way, as Hashbrown has it:
//  a list of commands narrowed by typing. A row with › doesn't run; it opens a step inside the palette (→ or ↩ goes in, Esc comes
//  back, and Esc closes from the first list). This model holds the steps, the typing, ↑↓, ↩, → and Esc, and the view
//  is thin, so the tests drive it as the keys do. What a command does is the host's (`CommandPaletteActions.swift`).
//  The tests compile this file.
//

import CoreGraphics
import Foundation
import Observation

/// A row the palette shows: a command, a step's choice, or the offer to search captures.
nonisolated struct PaletteRow: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    /// Muted, after the title ("Library", "in use").
    var detail = ""
    /// A second line, for a step's captures and recordings ("Screenshot · 1672 × 941 · Nov 9, 6:57 AM").
    var subtitle = ""
    var symbol: String?
    /// One keycap per key.
    var keys: [String] = []
    var opens: PaletteStep?
    /// Why it can't run now; the row is grey and ↩ does nothing.
    var reason: String?
    /// A switch's state.
    var isOn: Bool?
    /// A step's choice in use.
    var ticked = false
    var isBeta = false
    /// The heading it sits under in the first list.
    var group: PaletteGroup?
    /// Recent Captures and Recordings: the picture beside the name.
    var thumbnail: URL?
    /// The letters typing matched, for the Highlighter's swipe.
    var marks: [Range<Int>] = []
    /// Kept for the host: the command it runs, or the step it was found in from the first list and that step's own id
    /// for it (`choice`, when `id` had to change to stay unique in the first list).
    var command: String?
    var step: PaletteStep?
    var choice: String?

    /// The id the host gave the row in its step.
    var choiceID: String { choice ?? id }

    var isEnabled: Bool { reason == nil }
}

/// What the app says about a command now.
nonisolated struct PaletteCommandState: Sendable, Equatable {
    /// Left out of the list: the command doesn't apply here at all (a capture's selection with none selected).
    var isHidden = false
    /// A title that follows state ("Stop Recording", "Show Inspector").
    var title: String?
    var symbol: String?
    var detail: String?
    var reason: String?
    var isOn: Bool?

    static let ready = PaletteCommandState()
    static func off(_ reason: String) -> Self { PaletteCommandState(reason: reason) }
    static let hidden = PaletteCommandState(isHidden: true)
}

/// What ↩ leaves behind.
nonisolated enum PaletteOutcome: Sendable, Equatable {
    case close, stay
}

/// The keys the palette takes from the field.
nonisolated enum PaletteKey: Sendable, Equatable {
    case up, down, right, enter, escape
    /// ⌘C on a capture in Recent Captures.
    case copy
}

/// The app behind the palette: one per window it opened over.
@MainActor protocol CommandPaletteHost: AnyObject {
    var window: PaletteWindow { get }
    /// The selection's name for its heading ("Lake at dawn", "3 captures").
    var selectionTitle: String? { get }
    /// The key line's right side ("Library · Lake at dawn").
    var place: String { get }
    func state(of command: PaletteCommand) -> PaletteCommandState
    func keys(for command: PaletteCommand) -> [String]
    /// A step's rows, before narrowing; for a step that takes text, from what's typed.
    func rows(for step: PaletteStep, query: String) -> [PaletteRow]
    /// The step's own words on the key line's right ("Light theme", "10 captures").
    func place(for step: PaletteStep) -> String?
    func run(_ command: PaletteCommand) -> PaletteOutcome
    func choose(_ row: PaletteRow, in step: PaletteStep) -> PaletteOutcome
    /// ⌘C on a row of Recent Captures or Clipboard History.
    func copy(_ row: PaletteRow, in step: PaletteStep)
    /// Change Theme's try-on; nil puts the saved theme back.
    func tryOn(_ row: PaletteRow?)
    func searchCaptures(for text: String)
}

@MainActor @Observable
final class CommandPaletteModel {
    let host: CommandPaletteHost
    let catalog: [PaletteCommand]
    private(set) var steps: [PaletteStep] = [.commands]
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selected = 0
        }
    }
    var selected = 0 { didSet { if selected != oldValue { tryOn() } } }
    /// Called as the palette closes.
    @ObservationIgnored var onClose: () -> Void = {}
    /// A switch flipped or a tick changed: the rows are asked for again.
    private(set) var revision = 0
    /// While Change Theme is open and nothing was kept, Esc puts the saved theme back.
    private var tryingOn = false

    init(host: CommandPaletteHost, catalog: [PaletteCommand] = PaletteCommand.catalog, start: PaletteStep = .commands) {
        self.host = host
        self.catalog = catalog
        if start != .commands { enter(start) }
    }

    var step: PaletteStep { steps.last ?? .commands }
    var isFirstList: Bool { steps.count == 1 }
    var placeholder: String { step.placeholder }

    /// The first list found nothing for what's typed: the view says so over the offer to search the captures.
    var isNoMatch: Bool {
        guard step == .commands, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let rows = rows
        return rows.count == 1 && rows.first?.id == Self.searchCapturesID
    }

    static let searchCapturesID = "search-captures"

    // MARK: Keys

    /// One key from the field. Says whether the palette used it, so the field gets the rest (→ moves the caret).
    @discardableResult
    func press(_ key: PaletteKey) -> Bool {
        switch key {
        case .up: move(-1)
        case .down: move(1)
        case .enter: submit()
        case .right: return goIn()
        case .escape: back()
        case .copy:
            guard step == .recentCaptures || step == .clipboardHistory, let row = selectedRow else { return false }
            host.copy(row, in: step)
            close()
        }
        return true
    }

    func move(_ by: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selected = min(max(selected + by, 0), count - 1)
    }

    var selectedRow: PaletteRow? {
        let rows = rows
        return rows.indices.contains(selected) ? rows[selected] : nil
    }

    /// ↩: a row with › goes in; a grey row does nothing; any other runs.
    func submit() {
        guard let row = selectedRow, row.isEnabled else { return }
        if let next = row.opens { return enter(next) }
        let outcome: PaletteOutcome
        if row.id == Self.searchCapturesID {
            host.searchCaptures(for: query.trimmingCharacters(in: .whitespaces))
            outcome = .close
        } else if let id = row.command, let command = catalog.first(where: { $0.id == id }) {
            let result = host.run(command)
            // A switch flips and the palette stays for the next.
            outcome = command.isSwitch ? .stay : result
        } else if let found = row.step ?? (isFirstList ? nil : step) {
            if found == .changeTheme { tryingOn = false }
            outcome = host.choose(row, in: found)
        } else {
            return
        }
        if outcome == .close { close() } else { revision += 1 }
    }

    /// →: goes into a row with ›. Says whether it did, so the caret can move otherwise.
    @discardableResult
    func goIn() -> Bool {
        guard let row = selectedRow, row.isEnabled, let next = row.opens else { return false }
        enter(next)
        return true
    }

    /// Esc: back a step, or closes from the first. Leaving Change Theme puts the saved theme back.
    func back() {
        putThemeBack()
        guard steps.count > 1 else { return close() }
        steps.removeLast()
        query = ""
        selected = 0
    }

    func close() {
        putThemeBack()
        onClose()
    }

    private func enter(_ next: PaletteStep) {
        steps.append(next)
        query = ""
        tryingOn = next == .changeTheme
        // On the one in use, where there is one.
        selected = rows.firstIndex(where: \.ticked) ?? 0
        tryOn()
    }

    private func tryOn() {
        guard tryingOn, step == .changeTheme, let row = selectedRow else { return }
        host.tryOn(row)
    }

    private func putThemeBack() {
        guard tryingOn, step == .changeTheme else { return }
        tryingOn = false
        host.tryOn(nil)
    }

    // MARK: Rows

    var rows: [PaletteRow] {
        _ = revision
        if step == .commands { return firstList }
        let rows = host.rows(for: step, query: query)
        return step.appNarrows ? marked(rows) : narrowed(rows)
    }

    /// Rows the app narrowed, with the typed letters marked where the title holds them.
    private func marked(_ rows: [PaletteRow]) -> [PaletteRow] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !step.takesText else { return rows }
        return rows.map { row in
            var row = row
            row.marks = PaletteMatch.match(typed, in: row.title)?.ranges ?? []
            return row
        }
    }

    /// The step's own key line: the keys that work here and what they do.
    var hints: [(keys: [String], label: String)] {
        if isNoMatch { return [(["↩"], "search captures"), (["esc"], "close")] }
        switch step {
        case .commands: return [(["↩"], "run"), (["→"], "open a step"), (["esc"], "close"), (["↑", "↓"], "move")]
        case .changeTheme:
            let saved = host.rows(for: .changeTheme, query: "").first(where: \.ticked)?.title ?? "the theme"
            return [(["↩"], "keep it"), (["esc"], "put \(saved) back"), (["↑", "↓"], "try one")]
        case .recentCaptures: return [(["↩"], "open"), (["⌘", "C"], "copy"), (["esc"], "back")]
        case .clipboardHistory: return [(["↩"], "paste"), (["⌘", "C"], "copy"), (["esc"], "back")]
        case .addTag: return [(["↩"], "tick or untick"), (["esc"], "back")]
        case .searchCaptures: return [(["↩"], "search"), (["esc"], "back")]
        default: return [(["↩"], "choose"), (["esc"], "back"), (["↑", "↓"], "move")]
        }
    }

    var place: String { step == .commands ? host.place : host.place(for: step) ?? host.place }

    /// Every command for here, grouped, with its state; typed letters narrow and rank them, and also find the rows of
    /// steps that are searched from the first list ("Go to Received").
    private var firstList: [PaletteRow] {
        let window = host.window
        let listed: [(PaletteCommand, PaletteRow)] = catalog.compactMap { command in
            guard command.scope.isListed(in: window) else { return nil }
            let state = host.state(of: command)
            guard !state.isHidden else { return nil }
            return (command, PaletteRow(
                id: command.id, title: state.title ?? command.title, detail: state.detail ?? "",
                symbol: state.symbol ?? command.symbol, keys: host.keys(for: command), opens: command.step,
                reason: state.reason, isOn: command.isSwitch ? (state.isOn ?? false) : nil, isBeta: command.isBeta,
                group: command.group, command: command.id))
        }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            return listed.enumerated().sorted { ($0.element.0.group, $0.offset) < ($1.element.0.group, $1.offset) }.map(\.element.1)
        }
        // The window's own commands rank ahead of the ones that run in any window (0 before 1).
        var found: [(tier: PaletteMatch.Tier, own: Int, order: Int, row: PaletteRow)] = []
        for (order, (command, row)) in listed.enumerated() {
            guard let match = PaletteMatch.match(typed, in: row.title) else { continue }
            var row = row
            row.marks = match.ranges
            found.append((match.tier, command.scope.isWindowsOwn ? 0 : 1, order, row))
        }
        let deep = listed.compactMap { command, row in row.isEnabled ? command.step : nil }
            .filter { $0.titlePrefixInFirstList != nil }
        for (index, step) in deep.enumerated() {
            guard let prefix = step.titlePrefixInFirstList else { continue }
            for child in host.rows(for: step, query: "") where child.isEnabled {
                let title = "\(prefix) \(child.title)"
                // Matched on its own name, so "rec" finds Received and not the "Go to" in front.
                guard let match = PaletteMatch.match(typed, in: child.title) else { continue }
                var row = child
                row.id = "\(step.rawValue).\(child.id)"
                row.choice = child.choice ?? child.id
                row.title = title
                row.step = step
                row.opens = nil
                row.marks = match.ranges.map { ($0.lowerBound + prefix.count + 1) ..< ($0.upperBound + prefix.count + 1) }
                found.append((match.tier, 1, listed.count + index, row))
            }
        }
        guard !found.isEmpty else {
            return [PaletteRow(id: Self.searchCapturesID, title: "Search captures for “\(typed)”", symbol: "magnifyingglass",
                               keys: ["↩"])]
        }
        return found.sorted { ($0.tier, $0.own, $0.order) < ($1.tier, $1.own, $1.order) }.map(\.row)
    }

    /// A step's rows whose titles match what's typed, best first, marked.
    private func narrowed(_ rows: [PaletteRow]) -> [PaletteRow] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return rows }
        return rows.enumerated().compactMap { order, row -> (PaletteMatch.Tier, Int, PaletteRow)? in
            guard let match = PaletteMatch.match(typed, in: row.title) else { return nil }
            var row = row
            row.marks = match.ranges
            return (match.tier, order, row)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }
}
