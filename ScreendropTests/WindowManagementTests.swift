import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

@Suite
struct WindowManagementTests {
    // Primary 1920x1080 with 25 pt menu bar at top and 60 pt Dock at bottom -> AppKit visible y=60, h=995.
    private let primary = DisplayScreen.fromAppKit(
        frame: (0, 0, 1920, 1080),
        visibleFrame: (0, 60, 1920, 995),
        primaryHeight: 1080
    )

    // Secondary 2560x1440 to the right, bottom-aligned in AppKit (top extends 360 pt above primary -> AX y = -360).
    private let rightDisplay = DisplayScreen.fromAppKit(
        frame: (1920, 0, 2560, 1440),
        visibleFrame: (1920, 0, 2560, 1415),
        primaryHeight: 1080
    )

    @Test func appKitAndAXCoordinateFlipAcrossMultiDisplayArrangements() {
        #expect(primary.frame == ScreenBounds(x: 0, y: 0, width: 1920, height: 1080))
        #expect(primary.visibleFrame == ScreenBounds(x: 0, y: 25, width: 1920, height: 995))

        // Round-trip AX -> AppKit preserves menu bar and Dock insets on primary and secondary displays.
        #expect(primary.visibleFrame.toAppKit(primaryHeight: 1080) == CGRect(x: 0, y: 60, width: 1920, height: 995))
        #expect(rightDisplay.frame == ScreenBounds(x: 1920, y: -360, width: 2560, height: 1440))
        #expect(rightDisplay.visibleFrame == ScreenBounds(x: 1920, y: -335, width: 2560, height: 1415))
        #expect(rightDisplay.visibleFrame.toAppKit(primaryHeight: 1080) == CGRect(x: 1920, y: 0, width: 2560, height: 1415))

        // Display stacked directly ABOVE primary: AppKit y=1080, h=1080 -> AX y=-1080, bottom=0.
        let aboveDisplay = DisplayScreen.fromAppKit(
            frame: (0, 1080, 1920, 1080),
            visibleFrame: (0, 1080, 1920, 1055),
            primaryHeight: 1080
        )
        #expect(aboveDisplay.frame == ScreenBounds(x: 0, y: -1080, width: 1920, height: 1080))
        #expect(aboveDisplay.visibleFrame == ScreenBounds(x: 0, y: -1055, width: 1920, height: 1055))
        #expect(aboveDisplay.visibleFrame.toAppKit(primaryHeight: 1080) == CGRect(x: 0, y: 1080, width: 1920, height: 1055))

        // Left-side Dock (70 pt wide) on primary display.
        let leftDock = DisplayScreen.fromAppKit(
            frame: (0, 0, 1440, 900),
            visibleFrame: (70, 0, 1370, 875),
            primaryHeight: 900
        )
        #expect(leftDock.visibleFrame == ScreenBounds(x: 70, y: 25, width: 1370, height: 875))
    }

    @Test func allActionsOnSingleDisplayRespectMenuBarAndDock() {
        let win = ScreenBounds(x: 100, y: 100, width: 800, height: 600)
        let oneScreen = [primary]

        // Halves & odd-height split (995 -> top 497, bottom 498, no gap).
        #expect(WindowLayout.target(for: .leftHalf, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 0, y: 25, width: 960, height: 995))
        #expect(WindowLayout.target(for: .rightHalf, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 960, y: 25, width: 960, height: 995))
        #expect(WindowLayout.target(for: .topHalf, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 0, y: 25, width: 1920, height: 497))
        #expect(WindowLayout.target(for: .bottomHalf, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 0, y: 522, width: 1920, height: 498))

        // Quarters.
        #expect(WindowLayout.target(for: .topLeft, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 0, y: 25, width: 960, height: 497))
        #expect(WindowLayout.target(for: .topRight, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 960, y: 25, width: 960, height: 497))
        #expect(WindowLayout.target(for: .bottomLeft, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 0, y: 522, width: 960, height: 498))
        #expect(WindowLayout.target(for: .bottomRight, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 960, y: 522, width: 960, height: 498))

        // Maximize & Center.
        #expect(WindowLayout.target(for: .maximize, window: win, screens: oneScreen)?.frame == primary.visibleFrame)
        #expect(WindowLayout.target(for: .center, window: win, screens: oneScreen)?.frame
                == ScreenBounds(x: 560, y: 222, width: 800, height: 600))

        // Oversized window centered clamps to visibleFrame size.
        let huge = ScreenBounds(x: 0, y: 0, width: 3000, height: 2000)
        #expect(WindowLayout.target(for: .center, window: huge, screens: oneScreen)?.frame == primary.visibleFrame)

        // Next display on a single display is a no-op (returns nil).
        #expect(WindowLayout.target(for: .nextDisplay, window: win, screens: oneScreen) == nil)
        #expect(WindowLayout.target(for: .leftHalf, window: win, screens: []) == nil)
    }

    @Test func allActionsOnTwoDisplaysAndCrossDisplayMoves() {
        let screens = [primary, rightDisplay]
        let onRight = ScreenBounds(x: 2100, y: -200, width: 900, height: 700)

        // Halves, quarters, maximize, center on secondary display (negative AX Y).
        #expect(WindowLayout.target(for: .leftHalf, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 1920, y: -335, width: 1280, height: 1415))
        #expect(WindowLayout.target(for: .rightHalf, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 3200, y: -335, width: 1280, height: 1415))
        #expect(WindowLayout.target(for: .topHalf, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 1920, y: -335, width: 2560, height: 707))
        #expect(WindowLayout.target(for: .bottomHalf, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 1920, y: 372, width: 2560, height: 708))
        #expect(WindowLayout.target(for: .topLeft, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 1920, y: -335, width: 1280, height: 707))
        #expect(WindowLayout.target(for: .topRight, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 3200, y: -335, width: 1280, height: 707))
        #expect(WindowLayout.target(for: .bottomLeft, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 1920, y: 372, width: 1280, height: 708))
        #expect(WindowLayout.target(for: .bottomRight, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 3200, y: 372, width: 1280, height: 708))
        #expect(WindowLayout.target(for: .maximize, window: onRight, screens: screens)?.frame == rightDisplay.visibleFrame)
        #expect(WindowLayout.target(for: .center, window: onRight, screens: screens)?.frame
                == ScreenBounds(x: 2750, y: 22, width: 900, height: 700))

        // Next display cycles primary -> secondary and keeps maximized windows maximized.
        let moved = WindowLayout.target(for: .nextDisplay, window: primary.visibleFrame, screens: screens)
        #expect(moved?.crossDisplay == true)
        #expect(moved?.frame == rightDisplay.visibleFrame)

        // Next display wraps secondary -> primary and stays inside primary's visibleFrame.
        let back = WindowLayout.target(for: .nextDisplay, window: onRight, screens: screens)
        #expect(back?.crossDisplay == true)
        #expect(back?.visibleFrame == primary.visibleFrame)
        if let back {
            #expect(back.frame.minX >= primary.visibleFrame.minX)
            #expect(back.frame.minY >= primary.visibleFrame.minY)
            #expect(back.frame.maxX <= primary.visibleFrame.maxX)
            #expect(back.frame.maxY <= primary.visibleFrame.maxY)
        }

        // Screen selection for straddling and off-screen windows.
        let straddling = ScreenBounds(x: 1700, y: 100, width: 600, height: 400) // 220 on primary, 380 on right
        #expect(WindowLayout.screenIndex(for: straddling, in: screens) == 1)
        let offscreen = ScreenBounds(x: 6000, y: 100, width: 400, height: 300)
        #expect(WindowLayout.screenIndex(for: offscreen, in: screens) == 1)
    }

    @Test func clampedPositionKeepsMinimumSizeRefusalInsideVisibleFrame() {
        let win = ScreenBounds(x: 100, y: 100, width: 800, height: 600)
        let rightHalf = WindowLayout.target(for: .rightHalf, window: win, screens: [primary])!
        let clamped = WindowLayout.clampedPosition(
            desired: rightHalf.frame, actualWidth: 1100, actualHeight: 995, within: primary.visibleFrame
        )
        #expect(clamped.x == 820.0)
        #expect(clamped.y == 25.0)

        let clampedHuge = WindowLayout.clampedPosition(
            desired: rightHalf.frame, actualWidth: 2200, actualHeight: 1200, within: primary.visibleFrame
        )
        #expect(clampedHuge.x == 0.0)
        #expect(clampedHuge.y == 25.0)
    }

    @Test func appsSearchRanksLeftHalfAndWindowCommands() {
        let apps = LauncherCatalog([
            LauncherAppEntry(path: "/Applications/Safari.app", name: "Safari"),
            LauncherAppEntry(path: "/Applications/HalfLife.app", name: "HalfLife"),
            LauncherAppEntry(path: "/Applications/Maxon.app", name: "Maxon"),
            LauncherAppEntry(path: "/Applications/ControlCenter.app", name: "ControlCenter"),
        ])
        let folders = Zoxide.catalog([Zoxide.Folder(path: "/Users/me/left-half-notes", score: 50)])

        // Off by default: window commands are absent from both unfiltered list and search.
        let offSections = LauncherList.sections(query: "", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: false)
        #expect(!offSections.map(\.title).contains("Window Management"))
        let offSearch = LauncherList.sections(query: "left half", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: false)
        #expect(!offSearch.flatMap(\.rows).contains { if case .windowCommand = $0.kind { true } else { false } })

        // On: unfiltered list exposes all 11 commands under "Window Management".
        let onUnfiltered = LauncherList.sections(query: "", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
        #expect(onUnfiltered.map(\.title) == ["Applications", "Window Management", "Folders"])
        let wmRows = onUnfiltered[1].rows
        #expect(wmRows.count == 11)
        #expect(wmRows.first?.title == "Left Half")
        #expect(wmRows.first?.detail == "⌃⌥⌘←")

        // "left half" ranks Left Half #1 (prefix match, ahead of demoted folder).
        let leftHalfResults = LauncherList.sections(query: "left half", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
            .flatMap(\.rows)
        #expect(leftHalfResults.first?.kind == .windowCommand(.leftHalf))
        #expect(leftHalfResults.first?.title == "Left Half")
        #expect(leftHalfResults.first?.detail == "⌃⌥⌘←")

        // "half" finds all four half commands in canonical order (after app prefix "HalfLife").
        let halfResults = LauncherList.sections(query: "half", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
            .flatMap(\.rows)
        let halfCommands = halfResults.compactMap { row -> WindowAction? in
            if case .windowCommand(let action) = row.kind { return action }
            return nil
        }
        #expect(halfCommands == [.leftHalf, .rightHalf, .topHalf, .bottomHalf])

        // "max" finds Maximize, "center" finds Center.
        let maxResults = LauncherList.sections(query: "max", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
            .flatMap(\.rows)
        #expect(maxResults.contains { $0.kind == .windowCommand(.maximize) })

        let centerResults = LauncherList.sections(query: "center", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
            .flatMap(\.rows)
        #expect(centerResults.first?.kind == .windowCommand(.center))

        // `z ` keyword mode stays folders-only even with window commands enabled.
        let zResults = LauncherList.sections(query: "z left", apps: apps, folders: folders, favorites: LauncherFavorites(), includeWindowCommands: true)
            .flatMap(\.rows)
        #expect(zResults.allSatisfy { $0.kind == .folder })
    }

    @Test func nothingRegisteredWhileSettingIsOffAndAllElevenWhenOn() {
        let registry = WindowHotkeyRegistry<Int>()
        var nextID: UInt32 = 100
        var registered: [(HotkeyShortcut, UInt32)] = []
        var unregistered: [Int] = []
        var handleCounter = 0

        func sync(
            enabled: Bool,
            excluding: [WindowHotkeyRegistry<Int>.Claim] = [],
            refusing: Set<WindowAction> = []
        ) {
            registry.sync(
                enabled: enabled,
                excluding: excluding,
                nextID: { defer { nextID += 1 }; return nextID },
                register: { shortcut, id in
                    if let action = WindowAction.allCases.first(where: { $0.hotkeyShortcut == shortcut }),
                       refusing.contains(action) {
                        return nil
                    }
                    registered.append((shortcut, id))
                    handleCounter += 1
                    return handleCounter
                },
                unregister: { unregistered.append($0) }
            )
        }

        // Setting off: nothing is registered and no issues are reported.
        sync(enabled: false)
        #expect(registry.entries.isEmpty)
        #expect(registry.statuses.isEmpty)
        #expect(registry.issueMessages.isEmpty)
        #expect(registered.isEmpty)
        #expect(unregistered.isEmpty)

        // Setting on: all 11 shortcuts register with distinct handles and map back to their actions.
        sync(enabled: true)
        #expect(registry.entries.count == 11)
        #expect(registered.count == 11)
        #expect(registry.issueMessages.isEmpty)
        for entry in registry.entries {
            #expect(registry.action(for: entry.id) == entry.action)
            #expect(registry.activeShortcutLabel(for: entry.action) == entry.action.shortcutLabel)
        }

        // Exact shortcut bindings match Unleash and never clash with Sukusho's default shortcuts.
        let sukushoDefaults = CaptureHotkeyAction.allCases.map(\.defaultShortcut)
        for action in WindowAction.allCases {
            #expect(!sukushoDefaults.contains(where: action.hotkeyShortcut.overlaps),
                    "\(action.title) (\(action.shortcutLabel)) must not clash with a default Sukusho shortcut")
        }
        #expect(WindowAction.leftHalf.hotkeyShortcut == HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: Int(kVK_LeftArrow)))
        #expect(WindowAction.topRight.hotkeyShortcut == HotkeyShortcut(modifiers: [.control, .option, .shift], keyCode: Int(kVK_UpArrow)))
        #expect(WindowAction.maximize.hotkeyShortcut == HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: Int(kVK_ANSI_M)))
        #expect(WindowAction.center.hotkeyShortcut == HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: Int(kVK_ANSI_C)))
        #expect(WindowAction.nextDisplay.hotkeyShortcut == HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: Int(kVK_ANSI_N)))

        // Turning off unregisters all 11 and clears status/issues.
        sync(enabled: false)
        #expect(registry.entries.isEmpty)
        #expect(registry.statuses.isEmpty)
        #expect(unregistered.count == 11)

        // Yielded capture shortcut & Carbon refusal hide advertised shortcut labels, report reasons, and keep Apps runnable.
        sync(
            enabled: true,
            excluding: [.init(shortcut: WindowAction.maximize.hotkeyShortcut, owner: "Fullscreen")],
            refusing: [.center]
        )
        #expect(registry.entries.count == 9)
        #expect(registry.statuses[.maximize] == .yielded(to: "Fullscreen"))
        #expect(registry.statuses[.center] == .refused)
        #expect(registry.activeShortcutLabel(for: .maximize) == nil)
        #expect(registry.activeShortcutLabel(for: .center) == nil)
        #expect(registry.activeShortcutLabel(for: .leftHalf) == "⌃⌥⌘←")
        #expect(registry.issueMessages.count == 2)
        #expect(registry.issueMessages[0].contains("Maximize") && registry.issueMessages[0].contains("Fullscreen"))
        #expect(registry.issueMessages[1].contains("Center") && registry.issueMessages[1].contains("couldn’t be registered"))

        // Apps search still lists Maximize and Center without advertising their inactive shortcuts.
        let maxRows = LauncherList.sections(
            query: "max",
            apps: .empty,
            folders: .empty,
            favorites: LauncherFavorites(),
            includeWindowCommands: true,
            activeWindowShortcutLabel: { registry.activeShortcutLabel(for: $0) }
        ).flatMap(\.rows)
        #expect(maxRows.first?.kind == .windowCommand(.maximize))
        #expect(maxRows.first?.detail == nil)
    }

    @Test func axTimeoutAndDeadTargetAbortImmediately() {
        #expect(WindowAXPolicy.shouldAbort(.cannotComplete))
        #expect(WindowAXPolicy.shouldAbort(.apiDisabled))
        #expect(WindowAXPolicy.shouldAbort(.invalidUIElement))
        #expect(!WindowAXPolicy.shouldAbort(.noValue))
        #expect(!WindowAXPolicy.shouldAbort(.attributeUnsupported))
        #expect(!WindowAXPolicy.shouldAbort(.success))
    }

    @Test func capturedWindowTargetNeverFallsBackWhenOriginalDisappears() {
        // External target terminated or window closed -> fails with feedback instead of falling back.
        #expect(WindowTargetState<String, String>.external(isTerminated: true, window: "A").resolve(ownIsVisible: { _ in true })
                == .gone(WindowTargetState<String, String>.goneMessage))
        #expect(WindowTargetState<String, String>.external(isTerminated: false, window: nil).resolve(ownIsVisible: { _ in true })
                == .gone(WindowTargetState<String, String>.goneMessage))
        #expect(WindowTargetState<String, String>.external(isTerminated: false, window: "A").resolve(ownIsVisible: { _ in true })
                == .moveExternal("A"))

        // Own window closed or hidden -> fails with feedback instead of picking a different Sukusho window.
        #expect(WindowTargetState<String, String>.own(nil).resolve(ownIsVisible: { _ in true })
                == .gone(WindowTargetState<String, String>.goneMessage))
        #expect(WindowTargetState<String, String>.own("Library").resolve(ownIsVisible: { _ in false })
                == .gone(WindowTargetState<String, String>.goneMessage))
        #expect(WindowTargetState<String, String>.own("Library").resolve(ownIsVisible: { _ in true })
                == .moveOwn("Library"))

        // Unavailable target reports why.
        #expect(WindowTargetState<String, String>.unavailable.resolve(ownIsVisible: { _ in true })
                == .gone(WindowTargetState<String, String>.unavailableMessage))

        // Accessibility missing at open: asks for permission if still untrusted, or asks to reopen Apps once granted (no fresh lookup).
        #expect(WindowTargetState<String, String>.externalNeedsAccessibility(isTrustedNow: false).resolve(ownIsVisible: { _ in true })
                == .needsAccessibility)
        #expect(WindowTargetState<String, String>.externalNeedsAccessibility(isTrustedNow: true).resolve(ownIsVisible: { _ in true })
                == .reopenAfterGrant(WindowTargetState<String, String>.reopenAfterGrantMessage))

        // Focus check before presenting: accepts only when the same app is still frontmost.
        #expect(WindowCaptureFocusCheck.accept(capturedPID: 42, currentFrontPID: 42))
        #expect(!WindowCaptureFocusCheck.accept(capturedPID: 42, currentFrontPID: 99))
        #expect(!WindowCaptureFocusCheck.accept(capturedPID: 42, currentFrontPID: nil))
        #expect(!WindowCaptureFocusCheck.accept(capturedPID: nil, currentFrontPID: 42))
    }

    @Test func capturedExecutionAcknowledgesOriginatingPopupCloseBeforePlacement() {
        // Matching session: validates, closes originating popup on main, and only then places.
        var trace: [String] = []
        let moved = WindowCapturedExecution.run(
            isCurrent: { true },
            validateWindow: { trace.append("validate"); return true },
            confirmCloseOriginatingPopup: { trace.append("close"); return true },
            place: { trace.append("place"); return true }
        )
        #expect(moved == .moved)
        #expect(trace == ["validate", "close", "place"])

        // Popup dismissed or reopened before validation finished: newer popup untouched, placement never runs.
        var placedAfterEnd = false
        let ended = WindowCapturedExecution.run(
            isCurrent: { true },
            validateWindow: { true },
            confirmCloseOriginatingPopup: { false },
            place: { placedAfterEnd = true; return true }
        )
        #expect(ended == .sessionEnded)
        #expect(!placedAfterEnd)

        // Disappeared window fails with .gone without closing the popup or placing.
        var closedOnGone = false
        var placedOnGone = false
        let gone = WindowCapturedExecution.run(
            isCurrent: { true },
            validateWindow: { false },
            confirmCloseOriginatingPopup: { closedOnGone = true; return true },
            place: { placedOnGone = true; return true }
        )
        #expect(gone == .gone)
        #expect(!closedOnGone)
        #expect(!placedOnGone)

        // Cancellation between close confirmation and placement prevents placement.
        var current = true
        var placedAfterCancel = false
        let cancelled = WindowCapturedExecution.run(
            isCurrent: { current },
            validateWindow: { true },
            confirmCloseOriginatingPopup: { current = false; return true },
            place: { placedAfterCancel = true; return true }
        )
        #expect(cancelled == .cancelled)
        #expect(!placedAfterCancel)
    }

    @Test func closeHandshakeBlocksSupersededTokenAndExpiredCallbacksFromClosingPopup() {
        let gate = WindowOperationGate()

        // Case 1: Active token closes popup and returns true to the waiting worker.
        let tok1 = gate.begin()
        let hs1 = WindowCloseHandshake(token: tok1, gate: gate)
        var closed1 = 0
        #expect(hs1.deliverOnMain { closed1 += 1; return true })
        #expect(hs1.wait(timeout: 0.1))
        #expect(closed1 == 1)

        // Case 2: Second Run supersedes the first before main runs -> first callback must NOT close the popup.
        let tok2 = gate.begin()
        let hs2 = WindowCloseHandshake(token: tok2, gate: gate)
        _ = gate.begin() // second Run supersedes tok2
        var closed2 = 0
        #expect(!hs2.deliverOnMain { closed2 += 1; return true })
        #expect(closed2 == 0)
        #expect(!hs2.wait(timeout: 0.05))

        // Case 3: Worker wait times out before main runs -> callback expires and never closes the popup late.
        let tok3 = gate.begin()
        let hs3 = WindowCloseHandshake(token: tok3, gate: gate)
        #expect(!hs3.wait(timeout: 0.01))
        var closed3 = 0
        #expect(!hs3.deliverOnMain { closed3 += 1; return true })
        #expect(closed3 == 0)
    }

    @Test func operationGateSupersedesAndCancelsWaitingRetriesImmediately() {
        let gate = WindowOperationGate()
        let first = gate.begin()
        #expect(gate.isCurrent(first))

        // Superseding with a newer command wakes a waiting retry immediately instead of sleeping its full duration.
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var waitOutcome = true
        nonisolated(unsafe) var restored = false
        let startTime = Date()
        DispatchQueue.global().async {
            defer {
                restored = true
                done.signal()
            }
            started.signal()
            waitOutcome = gate.wait(token: first, duration: 5.0)
        }
        _ = started.wait(timeout: .now() + 2)
        let second = gate.begin()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(!waitOutcome, "superseded retry must not run")
        #expect(restored, "deferred AXEnhancedUserInterface restore still runs")
        #expect(Date().timeIntervalSince(startTime) < 1.0)
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))

        // Switching Window Management off cancels any pending command.
        gate.cancelAll()
        #expect(!gate.isCurrent(second))
    }

    @Test func enhancedUIGuardSkipsDisableWriteWhenCancelledDuringRead() {
        let gate = WindowOperationGate()
        let token = gate.begin()

        // Cancelled while reading AXEnhancedUserInterface -> no disable write is issued.
        var writes = 0
        let disabledWhenCancelled = WindowEnhancedUIGuard.disableIfNeeded(
            isCurrent: { gate.isCurrent(token) },
            readEnabled: {
                gate.cancelAll()
                return true
            },
            writeDisabled: {
                writes += 1
                return true
            }
        )
        #expect(!disabledWhenCancelled)
        #expect(writes == 0)

        // Still current after read -> disable write proceeds and reports true so caller restores on exit.
        let token2 = gate.begin()
        let disabledWhenCurrent = WindowEnhancedUIGuard.disableIfNeeded(
            isCurrent: { gate.isCurrent(token2) },
            readEnabled: { true },
            writeDisabled: {
                writes += 1
                return true
            }
        )
        #expect(disabledWhenCurrent)
        #expect(writes == 1)
    }

    @Test func fullScreenExitConfirmsOnlyOnExplicitFalseAndHandlesTransientErrors() {
        // Error classification: only `.success` + `false` confirms exit; `.noValue`/`.failure` stay transient.
        #expect(WindowFullScreenPoll.from(error: .success, boolValue: false) == .exited)
        #expect(WindowFullScreenPoll.from(error: .success, boolValue: true) == .fullScreen)
        #expect(WindowFullScreenPoll.from(error: .noValue, boolValue: nil) == .transientFailure)
        #expect(WindowFullScreenPoll.from(error: .failure, boolValue: nil) == .transientFailure)
        #expect(WindowFullScreenPoll.from(error: .success, boolValue: nil) == .transientFailure)
        #expect(WindowFullScreenPoll.from(error: .cannotComplete, boolValue: nil) == .abort)
        #expect(WindowFullScreenPoll.from(error: .invalidUIElement, boolValue: nil) == .abort)

        // Strict CFBoolean type check rejects numeric 0/1 NSNumbers and strings.
        #expect(WindowFullScreenPoll.cfBooleanValue(kCFBooleanTrue) == true)
        #expect(WindowFullScreenPoll.cfBooleanValue(kCFBooleanFalse) == false)
        #expect(WindowFullScreenPoll.cfBooleanValue(NSNumber(value: 0)) == nil)
        #expect(WindowFullScreenPoll.cfBooleanValue(NSNumber(value: 1)) == nil)
        #expect(WindowFullScreenPoll.cfBooleanValue("false" as CFString) == nil)
        #expect(WindowFullScreenPoll.cfBooleanValue(nil) == nil)
        #expect(WindowFullScreenPoll.from(error: .success, boolValue: WindowFullScreenPoll.cfBooleanValue(NSNumber(value: 0)))
                == .transientFailure)

        // Cancelled before exit write never writes AXFullScreen = false.
        var exitWrites = 0
        let cancelledBeforeWrite = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 5,
            shouldContinue: { false },
            requestExit: { exitWrites += 1; return .success },
            pollFullScreen: { .exited },
            waitStep: { true }
        )
        #expect(cancelledBeforeWrite == .cancelled)
        #expect(exitWrites == 0)

        // Rejected AXFullScreen write stops immediately without polling.
        var polls = 0
        let rejected = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 5,
            requestExit: { .attributeUnsupported },
            pollFullScreen: { polls += 1; return .exited },
            waitStep: { true }
        )
        #expect(rejected == .writeFailed)
        #expect(polls == 0)

        // Transient `.noValue`/`.failure` polls during transition do NOT falsely confirm exit; waits for `.exited`.
        var states: [WindowFullScreenPoll] = [.fullScreen, .transientFailure, .transientFailure, .exited]
        let exited = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 6,
            requestExit: { .success },
            pollFullScreen: { states.removeFirst() },
            waitStep: { true }
        )
        #expect(exited == .exited)
        #expect(states.isEmpty)

        // Persistent transient failures time out instead of placing prematurely.
        let transientTimeout = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 3,
            requestExit: { .success },
            pollFullScreen: { .transientFailure },
            waitStep: { true }
        )
        #expect(transientTimeout == .timedOut)

        // Window that stays full-screen past maxPolls times out instead of placing while full-screen.
        let timedOut = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 3,
            requestExit: { .success },
            pollFullScreen: { .fullScreen },
            waitStep: { true }
        )
        #expect(timedOut == .timedOut)

        // Cancelled mid-exit stops immediately.
        let cancelled = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 5,
            requestExit: { .success },
            pollFullScreen: { .fullScreen },
            waitStep: { false }
        )
        #expect(cancelled == .cancelled)

        // Messaging timeout / dead target aborts immediately.
        let readFailed = WindowFullScreenExit.exitAndConfirm(
            maxPolls: 5,
            requestExit: { .success },
            pollFullScreen: { .abort },
            waitStep: { true }
        )
        #expect(readFailed == .readFailed)
    }

    @Test func settleRetriesRequestedFrameThenPlacesFromActualSizeIncludingLeftTopEncroachment() {
        // 1440-wide visible frame; Right Half wants x=720, width=720.
        let screen = DisplayScreen.fromAppKit(
            frame: (0, 0, 1440, 900),
            visibleFrame: (0, 0, 1440, 875),
            primaryHeight: 900
        )
        let target = WindowLayout.target(
            for: .rightHalf,
            window: ScreenBounds(x: 100, y: 100, width: 1000, height: 875),
            screens: [screen]
        )!
        #expect(target.frame == ScreenBounds(x: 720, y: 25, width: 720, height: 875))

        // Case 1: First read still has stale width=1000; retry requests (720, 25, 720, 875) and resize succeeds.
        // Window must land at x=720 (not shifted to x=440 or left at x=1160).
        var frame1 = ScreenBounds(x: 720, y: 25, width: 1000, height: 875)
        var writtenFrames1: [ScreenBounds] = []
        var positionWrites1: [(Double, Double)] = []
        WindowLayout.settle(
            target: target,
            readFrame: { frame1 },
            writeFrame: { requested in
                writtenFrames1.append(requested)
                frame1 = requested
                return true
            },
            writePosition: { x, y in
                positionWrites1.append((x, y))
                frame1.x = x; frame1.y = y
            }
        )
        #expect(writtenFrames1 == [target.frame])
        #expect(positionWrites1.isEmpty)
        #expect(frame1 == ScreenBounds(x: 720, y: 25, width: 720, height: 875))

        // Case 2: App genuinely refuses width < 1000; after retrying requested frame, final origin shifts left to x=440.
        var frame2 = ScreenBounds(x: 720, y: 25, width: 1000, height: 875)
        WindowLayout.settle(
            target: target,
            readFrame: { frame2 },
            writeFrame: { requested in
                frame2 = ScreenBounds(x: requested.x, y: requested.y, width: max(1000, requested.width), height: requested.height)
                return true
            },
            writePosition: { x, y in frame2.x = x; frame2.y = y }
        )
        #expect(frame2 == ScreenBounds(x: 440, y: 25, width: 1000, height: 875))

        // Case 3: Left Dock (70 pt) + menu bar (25 pt) encroachment is caught on both x and y.
        let leftDock = DisplayScreen.fromAppKit(
            frame: (0, 0, 1440, 900),
            visibleFrame: (70, 0, 1370, 875),
            primaryHeight: 900
        )
        let leftTarget = WindowLayout.target(
            for: .leftHalf,
            window: ScreenBounds(x: 100, y: 100, width: 600, height: 600),
            screens: [leftDock]
        )!
        let encroaching = ScreenBounds(x: 0, y: 0, width: 685, height: 875)
        let corrected = WindowLayout.finalOriginCorrection(actual: encroaching, target: leftTarget)
        #expect(corrected?.x == 70.0)
        #expect(corrected?.y == 25.0)

        // Case 4: Cancellation before retry write or before final position correction blocks the stale write.
        var cancelledAfterRead = true
        var retryWrites = 0
        var posWrites = 0
        WindowLayout.settle(
            target: target,
            shouldContinue: { !cancelledAfterRead },
            readFrame: {
                cancelledAfterRead = true
                return ScreenBounds(x: 720, y: 25, width: 1000, height: 875)
            },
            writeFrame: { _ in retryWrites += 1; return true },
            writePosition: { _, _ in posWrites += 1 }
        )
        #expect(retryWrites == 0 && posWrites == 0)

        var reads = 0
        var allowWrite = true
        WindowLayout.settle(
            target: target,
            shouldContinue: { allowWrite },
            readFrame: {
                reads += 1
                if reads == 2 { allowWrite = false } // cancelled right before final position correction
                return ScreenBounds(x: 720, y: 25, width: 1000, height: 875)
            },
            writeFrame: { _ in retryWrites += 1; return true },
            writePosition: { _, _ in posWrites += 1 }
        )
        #expect(retryWrites == 1 && posWrites == 0)
    }

    @Test func accessibilityFlowPromptsOnceThenOpensSettingsOnRepeatUserAction() {
        #expect(AccessibilityPermissionFlow.decide(isTrusted: true, hasPromptedBefore: false) == .granted)
        #expect(AccessibilityPermissionFlow.decide(isTrusted: true, hasPromptedBefore: true) == .granted)
        #expect(AccessibilityPermissionFlow.decide(isTrusted: false, hasPromptedBefore: false) == .promptSystem)
        #expect(AccessibilityPermissionFlow.decide(isTrusted: false, hasPromptedBefore: true) == .openSettings)
    }
}
