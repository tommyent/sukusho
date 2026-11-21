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

        func sync(enabled: Bool, excluding: [HotkeyShortcut] = []) {
            registry.sync(
                enabled: enabled,
                excluding: excluding,
                nextID: { defer { nextID += 1 }; return nextID },
                register: { shortcut, id in
                    registered.append((shortcut, id))
                    handleCounter += 1
                    return handleCounter
                },
                unregister: { unregistered.append($0) }
            )
        }

        // Setting off: nothing is registered.
        sync(enabled: false)
        #expect(registry.entries.isEmpty)
        #expect(registered.isEmpty)
        #expect(unregistered.isEmpty)

        // Setting on: all 11 shortcuts register with distinct handles and map back to their actions.
        sync(enabled: true)
        #expect(registry.entries.count == 11)
        #expect(registered.count == 11)
        for entry in registry.entries {
            #expect(registry.action(for: entry.id) == entry.action)
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

        // Turning off unregisters all 11 and leaves zero active registrations.
        sync(enabled: false)
        #expect(registry.entries.isEmpty)
        #expect(unregistered.count == 11)

        // User-recorded capture shortcut overlapping a window shortcut takes precedence.
        sync(enabled: true, excluding: [WindowAction.maximize.hotkeyShortcut])
        #expect(registry.entries.count == 10)
        #expect(!registry.entries.contains { $0.action == .maximize })
    }
}
