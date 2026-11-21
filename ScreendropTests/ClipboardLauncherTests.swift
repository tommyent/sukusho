import Foundation
import Testing

@Suite
struct ClipboardLauncherSearchTests {
    private func app(_ name: String, _ path: String? = nil, _ version: String? = nil) -> LauncherAppEntry {
        LauncherAppEntry(path: path ?? "/Applications/\(name).app", name: name, version: version)
    }

    private func names(_ catalog: LauncherCatalog, _ indices: [Int]) -> [String] {
        indices.map { catalog.apps[$0].name }
    }

    @Test func rankingTiers() {
        #expect(LauncherCatalog.tier(of: "Codex", for: "code") == .prefix)
        #expect(LauncherCatalog.tier(of: "Visual Studio Code", for: "code") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "Xcode", for: "code") == .substring)
        #expect(LauncherCatalog.tier(of: "Visual Studio Code", for: "vsc") == .initials)
        #expect(LauncherCatalog.tier(of: "Calculator", for: "clc") == .subsequence)
        #expect(LauncherCatalog.tier(of: "Calculator", for: "xyz") == nil)
        #expect(LauncherCatalog.tier(of: "VISUAL Studio", for: "visual") == .prefix)
        #expect(LauncherCatalog.tier(of: "Café Tools", for: "cafe") == .prefix)
        #expect(LauncherCatalog.tier(of: "Équipe", for: "equ") == .prefix)
        #expect(LauncherCatalog.tier(of: "Visual Studio Code", for: "visual studio") == .prefix)
        #expect(LauncherCatalog.tier(of: "Visual Studio Code", for: "studio co") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "TextEdit", for: "edit") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "1Password", for: "pass") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "Visual Studio Code", for: "vs code") == .subsequence)
        #expect(LauncherCatalog.tier(of: "Google Chrome", for: "gc") == .initials)
        #expect(LauncherCatalog.tier(of: "Ünïcödé Äpp", for: "ua") == .initials)
    }

    @Test func nonASCIIScalarMatching() {
        // ぁ (E3 81 81) + ゃ (E3 82 83) contains UTF-8 bytes of あ (E3 81 82) in order; scalar matching must not match.
        #expect(LauncherCatalog.tier(of: "ぁゃ", for: "あ") == nil)
        #expect(LauncherCatalog.tier(of: "写真編集", for: "写真") == .prefix)
        #expect(LauncherCatalog.tier(of: "写真編集", for: "編集") == .substring)
        #expect(LauncherCatalog.tier(of: "写真 編集", for: "写編") == .initials)
        #expect(LauncherCatalog.tier(of: "写真編集", for: "写集") == .subsequence)
        #expect(LauncherCatalog.tier(of: "Привет Мир", for: "мир") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "Привет Мир", for: "пм") == .initials)
        #expect(LauncherCatalog.tier(of: "Привет Мир", for: "пвт") == .subsequence)
        #expect(LauncherCatalog.tier(of: "Ελληνικά", for: "ελληνικα") == .prefix)
        #expect(LauncherCatalog.tier(of: "🎵 Music", for: "music") == .wordPrefix)
        #expect(LauncherCatalog.tier(of: "🎵 Music", for: "🎵") == .prefix)

        let catalog = LauncherCatalog([app("ぁゃ"), app("あい"), app("Notes")])
        #expect(names(catalog, catalog.search("あ", pinned: [nil, nil, nil])) == ["あい"])
    }

    @Test func rankedSearchAndFavoritesWithinTier() {
        let catalog = LauncherCatalog([
            app("Xcode"), app("Visual Studio Code"), app("Codex"), app("Code Runner"),
            app("Calendar"), app("Console"),
        ])
        let none = [Int?](repeating: nil, count: catalog.count)
        #expect(names(catalog, catalog.search("code", pinned: none))
                == ["Code Runner", "Codex", "Visual Studio Code", "Xcode"])
        #expect(names(catalog, catalog.search("  code", pinned: none)).first == "Code Runner")
        #expect(catalog.search("   ", pinned: none) == [])
        #expect(catalog.search("qqq", pinned: none) == [])

        var fav = none
        fav[catalog.index(ofPath: "/Applications/Codex.app")!] = 0
        fav[catalog.index(ofPath: "/Applications/Xcode.app")!] = 1
        #expect(names(catalog, catalog.search("code", pinned: fav))
                == ["Codex", "Code Runner", "Visual Studio Code", "Xcode"])
    }

    @Test func favoritesPinOrderAndSharedLastTier() {
        let c1 = LauncherCatalog([app("Alpha Code"), app("Code A"), app("Code B"), app("Code C")])
        var pins = [Int?](repeating: nil, count: c1.count)
        pins[c1.index(ofPath: "/Applications/Code C.app")!] = 0
        pins[c1.index(ofPath: "/Applications/Code A.app")!] = 1
        #expect(names(c1, c1.search("code", pinned: pins)) == ["Code C", "Code A", "Code B", "Alpha Code"])

        let c2 = LauncherCatalog([app("Vast Scale Calc"), app("Devscope"), app("Vasco")])
        let none = [Int?](repeating: nil, count: c2.count)
        #expect(names(c2, c2.search("vsc", pinned: none)) == ["Devscope", "Vast Scale Calc", "Vasco"])
        var fav = none
        fav[c2.index(ofPath: "/Applications/Vasco.app")!] = 0
        #expect(names(c2, c2.search("vsc", pinned: fav)) == ["Devscope", "Vasco", "Vast Scale Calc"])
    }

    @Test func mergingAppsAndDemotedFolders() {
        let apps = [
            (value: "Adobe Premiere Pro", id: "/A/Premiere.app", tier: LauncherMatchTier.wordPrefix),
            (value: "Proxyman", id: "/A/Proxyman.app", tier: .prefix),
            (value: "1Password", id: "/A/1Password.app", tier: .subsequence),
        ]
        let folders = [
            (value: "Projects", id: "/U/Projects", tier: LauncherMatchTier.prefix),
            (value: "pr-play", id: "/U/pr-play", tier: .subsequence),
        ]
        #expect(LauncherRanking.merge([(apps, false), (folders, false)], favorites: [])
                == ["Proxyman", "Projects", "Adobe Premiere Pro", "1Password", "pr-play"])
        #expect(LauncherRanking.merge([(apps, false), (folders, true)], favorites: [])
                == ["Proxyman", "Adobe Premiere Pro", "Projects", "1Password", "pr-play"])
        #expect(LauncherRanking.merge([(apps, false), (folders, true)], favorites: ["/U/Projects", "/A/Proxyman.app"])
                == ["Projects", "Proxyman", "Adobe Premiere Pro", "1Password", "pr-play"])
    }

    @Test func sortingAndDuplicateDisambiguation() {
        let sorted = LauncherCatalog([
            app("zeta"), app("Alpha"), app("Émile"), app("beta"), app("App 10"), app("App 9"),
            app("alpha", "/Users/x/Applications/alpha.app"),
        ])
        #expect(sorted.apps.map(\.name) == ["Alpha", "alpha", "App 9", "App 10", "beta", "Émile", "zeta"])

        let home = "/Users/someone"
        let dupes = LauncherCatalog([
            app("Sukusho", "/Applications/Sukusho.app", "1.3.0 beta 1"),
            app("Sukusho", "/Applications/Betas/Sukusho.app", "1.3.0 beta 3"),
            app("sukusho", "/Users/someone/Applications/Sukusho.app", "1.3.0 beta 4"),
            app("Messages", "/System/Applications/Messages.app", "14.0"),
            app("Messages", "/Users/someone/Applications/Chrome Apps.localized/Messages.app", "14.0"),
            app("Notes", "/Applications/Notes.app"),
            app("Notes", "/Volumes/Old/Notes.app"),
            app("Safari", "/Applications/Safari.app", "26.0"),
        ], home: home)
        func detail(_ path: String) -> String? { dupes.details[dupes.index(ofPath: path)!] }
        #expect(detail("/Applications/Sukusho.app") == "1.3.0 beta 1")
        #expect(detail("/Applications/Betas/Sukusho.app") == "1.3.0 beta 3")
        #expect(detail("/Users/someone/Applications/Sukusho.app") == "1.3.0 beta 4")
        #expect(detail("/System/Applications/Messages.app") == "/System/Applications")
        #expect(detail("/Users/someone/Applications/Chrome Apps.localized/Messages.app") == "~/Applications/Chrome Apps.localized")
        #expect(detail("/Volumes/Old/Notes.app") == "/Volumes/Old")
        #expect(detail("/Applications/Safari.app") == nil)
    }

    @Test func sectionsSeparateFavoritesAppsAndFoldersAndRouteZKeyword() {
        let apps = LauncherCatalog([app("Proxyman"), app("Adobe Premiere Pro"), app("Safari")])
        let low = "/Users/me/proj-low"
        let high = "/Users/me/proj-high"
        let folders = Zoxide.catalog([
            Zoxide.Folder(path: low, score: 12),
            Zoxide.Folder(path: high, score: 96),
            Zoxide.Folder(path: "/Users/me/Projects/dev/unleash-swift", score: 50),
        ])
        let favs = LauncherFavorites(["/Applications/Safari.app", low])

        let unfiltered = LauncherList.sections(query: "", apps: apps, folders: folders, favorites: favs, home: "/Users/me")
        #expect(unfiltered.map(\.title) == ["Favorites", "Applications", "Folders"])
        #expect(unfiltered[0].rows.map(\.id) == [
            LauncherRowID(inFavorites: true, path: "/Applications/Safari.app"),
            LauncherRowID(inFavorites: true, path: low),
        ])
        #expect(unfiltered[1].rows.map(\.id).contains(LauncherRowID(inFavorites: false, path: "/Applications/Safari.app")))

        // Normal search puts pinned lower-score folder before unpinned higher-score folder.
        let normalProj = LauncherList.sections(query: "proj", apps: apps, folders: folders, favorites: favs, home: "/Users/me")
        #expect(normalProj.flatMap(\.rows).map(\.path) == [low, high])

        // `z ` keyword routes strictly through zoxide matching in score order, beating pinned lower-score folders.
        let zProj = LauncherList.sections(query: "z proj", apps: apps, folders: folders, favorites: favs, home: "/Users/me")
        #expect(zProj.flatMap(\.rows).map(\.path) == [high, low])
        #expect(zProj.flatMap(\.rows).allSatisfy { $0.kind == .folder })

        // "pro" keeps app prefix/word-prefix above unpinned folder prefix.
        let pro = LauncherList.sections(query: "pro", apps: apps, folders: folders, favorites: LauncherFavorites(), home: "/Users/me")
        #expect(pro.flatMap(\.rows).map(\.title) == ["Proxyman", "Adobe Premiere Pro", "proj-high", "proj-low"])
    }

    @Test func movedSelectionAdvancesAndClampsWithoutRebuilding() {
        let rows = (0..<5).map { i in
            LauncherRow(
                id: LauncherRowID(inFavorites: false, path: "/tmp/f\(i)"),
                kind: .folder, path: "/tmp/f\(i)", title: "f\(i)", detail: "/tmp", isFavorite: false
            )
        }
        #expect(LauncherList.movedSelection(from: nil, by: 1, in: []) == nil)
        #expect(LauncherList.movedSelection(from: nil, by: 1, in: rows) == rows[1].id)
        #expect(LauncherList.movedSelection(from: nil, by: -1, in: rows) == rows[0].id)
        #expect(LauncherList.movedSelection(from: rows[3].id, by: 1, in: rows) == rows[4].id)
        #expect(LauncherList.movedSelection(from: rows[4].id, by: 1, in: rows) == rows[4].id)
        #expect(LauncherList.movedSelection(from: rows[3].id, by: -1, in: rows) == rows[2].id)
        // A stale selection ID falls back to index 0.
        let stale = LauncherRowID(inFavorites: false, path: "/tmp/gone")
        #expect(LauncherList.movedSelection(from: stale, by: 1, in: rows) == rows[1].id)
    }

    @Test func scannerSyntheticTreeAndFavoritesPersistence() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sukusho-launcher-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func bundle(_ rel: String, version: String?) throws {
            let path = root.appendingPathComponent(rel).path
            try fm.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": (path as NSString).lastPathComponent]
            if let version { info["CFBundleShortVersionString"] = version }
            (info as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        }
        try bundle("Apps/Alpha.app", version: "1.0")
        try bundle("Apps/Utilities/Beta.app", version: nil)
        try bundle("Apps/Utilities/Deeper/Gamma.app", version: "3")
        try bundle("Apps/.Hidden.app", version: "1")
        try bundle("Home/Chrome Apps.localized/Delta.app", version: "  ")
        try bundle("Extra/Epsilon.app", version: "5.1")
        try bundle("Outside/Sneaky.app", version: "9.0")
        try bundle("OutsideDir/Nested.app", version: "9.1")
        try fm.createSymbolicLink(atPath: root.path + "/Apps/Alias.app", withDestinationPath: root.path + "/Apps/Alpha.app")
        try fm.createSymbolicLink(atPath: root.path + "/Apps/Escaping.app", withDestinationPath: root.path + "/Outside/Sneaky.app")
        try fm.createSymbolicLink(atPath: root.path + "/Apps/LinkedOutside", withDestinationPath: root.path + "/OutsideDir")
        fm.createFile(atPath: root.path + "/Apps/readme.app", contents: Data())

        let found = LauncherAppScanner.scan(
            [.init(root.path + "/Apps", depth: 1), .init(root.path + "/Home", depth: 1), .init(root.path + "/Missing", depth: 1)],
            extras: [root.path + "/Extra/Epsilon.app", root.path + "/Apps/Alpha.app"]
        )
        let byName = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let alpha = byName["Alpha"] ?? byName["Alias"]
        #expect(Set(byName.keys).subtracting(["Alpha", "Alias"]) == ["Beta", "Delta", "Epsilon"])
        #expect(byName["Sneaky"] == nil && byName["Escaping"] == nil && byName["Nested"] == nil)
        #expect(found.count == 4)
        #expect(alpha?.version == "1.0")
        #expect(byName["Beta"]?.version == nil)
        #expect(byName["Delta"]?.version == nil)

        // Favorites round-trip and corrupt file resilience.
        let favURL = root.appendingPathComponent("nested/favorites.json")
        #expect(LauncherFavorites.load(favURL) == LauncherFavorites())
        var favs = LauncherFavorites()
        let pinnedA = favs.toggle("/A.app")
        let pinnedB = favs.toggle("/B.app")
        let pinnedC = favs.toggle("/C.app")
        let unpinnedB = favs.toggle("/B.app")
        #expect(pinnedA && pinnedB && pinnedC)
        #expect(!unpinnedB)
        try favs.save(favURL)
        var reloaded = LauncherFavorites.load(favURL)
        #expect(reloaded.paths == ["/A.app", "/C.app"])
        reloaded.toggle("/B.app")
        try reloaded.save(favURL)
        #expect(LauncherFavorites.load(favURL).paths == ["/A.app", "/C.app", "/B.app"])
        try Data("not json".utf8).write(to: favURL)
        #expect(LauncherFavorites.load(favURL) == LauncherFavorites())

        // App cache round-trip.
        let cacheURL = root.appendingPathComponent("apps.json")
        let apps = [app("Alpha", nil, "1"), app("Beta")]
        try LauncherStore.write(apps, to: cacheURL)
        #expect(LauncherStore.loadApps(cacheURL) == apps)
    }

    @Test func importsUnleashFavoritesOnFirstUseLeavingOriginalInPlace() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sukusho-launcher-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // Case 1: imports current Unleash file, filters non-absolute entries, preserves order & unavailable targets, keeps original.
        let current1 = root.appendingPathComponent("c1/Sukusho/Launcher/favorites.json")
        let unleash1 = root.appendingPathComponent("c1/Unleash/favorites.json")
        let legacy1 = root.appendingPathComponent("c1/Unleash-swift/favorites.json")
        try LauncherFavorites(["/Applications/Safari.app", "relative/skip", "/Volumes/Offline/Missing.app", "/Users/me/Projects"]).save(unleash1)
        try LauncherFavorites(["/Applications/LegacyOnly.app"]).save(legacy1)
        let imported1 = LauncherFavorites.loadOrImport(from: current1, fallbacks: [unleash1, legacy1])
        #expect(imported1.paths == ["/Applications/Safari.app", "/Volumes/Offline/Missing.app", "/Users/me/Projects"])
        #expect(LauncherFavorites.load(current1).paths == imported1.paths)
        #expect(fm.fileExists(atPath: unleash1.path))

        // Case 2: falls back to Unleash-swift when current Unleash file is absent.
        let current2 = root.appendingPathComponent("c2/Sukusho/Launcher/favorites.json")
        let unleash2 = root.appendingPathComponent("c2/Unleash/favorites.json")
        let legacy2 = root.appendingPathComponent("c2/Unleash-swift/favorites.json")
        try LauncherFavorites(["/System/Applications/Calculator.app"]).save(legacy2)
        let imported2 = LauncherFavorites.loadOrImport(from: current2, fallbacks: [unleash2, legacy2])
        #expect(imported2.paths == ["/System/Applications/Calculator.app"])
        #expect(fm.fileExists(atPath: legacy2.path))

        // Case 3: existing Sukusho file (even empty) is never overwritten by Unleash fallbacks.
        let current3 = root.appendingPathComponent("c3/Sukusho/Launcher/favorites.json")
        let unleash3 = root.appendingPathComponent("c3/Unleash/favorites.json")
        try LauncherFavorites([]).save(current3)
        try LauncherFavorites(["/Applications/Safari.app"]).save(unleash3)
        #expect(LauncherFavorites.loadOrImport(from: current3, fallbacks: [unleash3]).paths == [])
    }

    @Test func realMacScanFindsStandardApps() {
        let real = LauncherAppScanner.scan()
        let paths = Set(real.map(\.path))
        #expect(paths.contains(LauncherAppScanner.finder))
        #expect(paths.contains("/System/Applications/Calculator.app"))
        #expect(paths.contains("/System/Applications/Utilities/Terminal.app"))
        #expect(paths.contains("/Applications/Safari.app"))
        #expect(!real.contains { $0.name.hasSuffix(".app") })
        #expect(paths.count == real.count)
    }
}

@Suite
struct ClipboardLauncherZoxideTests {
    @Test func parsesOutputAndRunsStubBinary() throws {
        let output = "  96.0 /Users/me/Projects\n   9.5 /Users/me/My Folder\n12345.6 /tmp/a  b \n"
            + "garbage\n  1.0 relative/path\n   0.3 /\n"
        #expect(Zoxide.parse(output) == [
            Zoxide.Folder(path: "/Users/me/Projects", score: 96),
            Zoxide.Folder(path: "/Users/me/My Folder", score: 9.5),
            Zoxide.Folder(path: "/tmp/a  b ", score: 12345.6),
            Zoxide.Folder(path: "/", score: 0.3),
        ])
        #expect(Zoxide.parse("") == [])

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sukusho-zoxide-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func stub(_ name: String, _ script: String) -> String {
            let path = dir.appendingPathComponent(name).path
            fm.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
            return path
        }
        let good = stub("zoxide", """
            #!/bin/sh
            [ "$*" = "query --list --score --all" ] || exit 3
            printf '  42.0 /tmp/with space\\n   1.5 /tmp/b\\n'
            """)
        #expect(Zoxide.folders(binary: good) == [
            Zoxide.Folder(path: "/tmp/with space", score: 42),
            Zoxide.Folder(path: "/tmp/b", score: 1.5),
        ])
        #expect(Zoxide.folders(binary: stub("failing", "#!/bin/sh\nexit 1\n")) == nil)
        #expect(Zoxide.fetch(binary: stub("failing2", "#!/bin/sh\nexit 2\n")) == .failed)
        #expect(Zoxide.folders(binary: dir.appendingPathComponent("missing").path) == nil)
        #expect(Zoxide.binary(in: [dir.appendingPathComponent("missing").path, good]) == good)
        #expect(Zoxide.binary(in: [dir.appendingPathComponent("missing").path]) == nil)

        // Hanging binary is terminated on timeout and on cancellation.
        let hanging = stub("hanging", "#!/bin/sh\nexec sleep 30\n")
        let timeoutStart = Date()
        #expect(Zoxide.fetch(binary: hanging, timeout: 0.2) == .failed)
        #expect(Date().timeIntervalSince(timeoutStart) < 2.0)

        let cancelStart = Date()
        let session = LauncherSession()
        let tok = session.begin()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(80)) { session.invalidate() }
        #expect(Zoxide.fetch(binary: hanging, timeout: 5.0, isCancelled: { !session.isCurrent(tok) }) == .cancelled)
        #expect(Date().timeIntervalSince(cancelStart) < 2.0)

        // Output exceeding maxBytes is rejected instead of growing unbounded.
        let noisy = stub("noisy", "#!/bin/sh\nhead -c 2048 /dev/zero | tr '\\0' 'a'\n")
        #expect(Zoxide.fetch(binary: noisy, timeout: 2.0, maxBytes: 512) == .failed)
    }

    @Test func entriesSkipAppBundlesWithoutProbingFilesystem() {
        #expect(Zoxide.entries([
            Zoxide.Folder(path: "/Applications/X.app", score: 3),
            Zoxide.Folder(path: "/Applications/X.app/Contents", score: 5),
            Zoxide.Folder(path: "/nonexistent/never-probed", score: 2),
        ]).map(\.path) == ["/nonexistent/never-probed"])
    }

    @Test func zoxideKeywordAndMatchingAndScoreRanking() {
        #expect(Zoxide.keywordQuery("z proj") == "proj")
        #expect(Zoxide.keywordQuery("z ") == "")
        #expect(Zoxide.keywordQuery("z") == nil)
        #expect(Zoxide.keywordQuery("zoom") == nil)
        #expect(Zoxide.keywordQuery(" z proj") == nil)

        let folders = [
            Zoxide.Folder(path: "/Users/me/Projects/dev/unleash-swift", score: 32),
            Zoxide.Folder(path: "/Users/me/Projects/old-proj", score: 12),
            Zoxide.Folder(path: "/Users/me/Projects", score: 96),
            Zoxide.Folder(path: "/Users/me/Work/dev/notes", score: 50),
            Zoxide.Folder(path: "/Users/me/Projects/dev/proj-lab", score: 20),
        ]

        #expect(Zoxide.match("proj", in: folders).map(\.path)
                == ["/Users/me/Projects", "/Users/me/Projects/dev/proj-lab", "/Users/me/Projects/old-proj"])
        #expect(Zoxide.match("PROJ", in: folders).map(\.path)
                == ["/Users/me/Projects", "/Users/me/Projects/dev/proj-lab", "/Users/me/Projects/old-proj"])
        #expect(Zoxide.match("dev unl", in: folders).map(\.path) == ["/Users/me/Projects/dev/unleash-swift"])
        #expect(Zoxide.match("proj dev unl", in: folders).map(\.path) == ["/Users/me/Projects/dev/unleash-swift"])
        #expect(Zoxide.match("dev proj unl", in: folders).map(\.path) == [])
        #expect(Zoxide.match("unl dev", in: folders).map(\.path) == [])
        #expect(Zoxide.match("nope", in: folders).map(\.path) == [])
        #expect(Zoxide.match("dev nope", in: folders).map(\.path) == [])
        #expect(Zoxide.match("", in: folders).map(\.path) == [
            "/Users/me/Projects", "/Users/me/Work/dev/notes", "/Users/me/Projects/dev/unleash-swift",
            "/Users/me/Projects/dev/proj-lab", "/Users/me/Projects/old-proj",
        ])
        #expect(Zoxide.match("   ", in: folders).map(\.path) == [
            "/Users/me/Projects", "/Users/me/Work/dev/notes", "/Users/me/Projects/dev/unleash-swift",
            "/Users/me/Projects/dev/proj-lab", "/Users/me/Projects/old-proj",
        ])
        #expect(Zoxide.matches("/Users/me/dev/other/dev", query: "other dev"))
        #expect(!Zoxide.matches("/Users/me/dev/other", query: "other dev"))
        #expect(Zoxide.matches("/Users/me/Projects/dev/unleash-swift", query: "unl swift"))
        #expect(!Zoxide.matches("/Users/me/Projects/dev/unleash-swift", query: "swift unl"))
        #expect(!Zoxide.matches("/Users/me/aba", query: "ab ba"))
        #expect(Zoxide.matches("/Users/me/abba", query: "ab ba"))
    }

    @Test func zoxideUnicodeParity() {
        let german = [
            Zoxide.Folder(path: "/Users/me/Strasse", score: 96),
            Zoxide.Folder(path: "/Users/me/Straße", score: 12),
        ]
        #expect(Zoxide.match("straße", in: german).map(\.path) == ["/Users/me/Straße"])
        #expect(Zoxide.match("strasse", in: german).map(\.path) == ["/Users/me/Strasse"])
        #expect(Zoxide.match("STRAẞE", in: german).map(\.path) == ["/Users/me/Straße"])

        let composedCafe = "/Users/me/nfc/Caf\u{00E9}"
        let decomposedCafe = "/Users/me/nfd/Cafe\u{0301}"
        let cafes = [
            Zoxide.Folder(path: composedCafe, score: 96),
            Zoxide.Folder(path: decomposedCafe, score: 12),
        ]
        #expect(Zoxide.match("caf\u{00E9}", in: cafes).map(\.path) == [composedCafe])
        #expect(Zoxide.match("cafe\u{0301}", in: cafes).map(\.path) == [decomposedCafe])
        #expect(Zoxide.match("CAF\u{00C9}", in: cafes).map(\.path) == [composedCafe])
        #expect(Zoxide.match("CAFE\u{0301}", in: cafes).map(\.path) == [decomposedCafe])
        #expect(Zoxide.matches("/Users/me/CAFE\u{0301}", query: "cafe\u{0301}"))
        #expect(!Zoxide.matches("/Users/me/CAFE\u{0301}", query: "caf\u{00E9}"))

        let os = [Zoxide.Folder(path: "/Users/me/ΟΣ", score: 50)]
        #expect(Zoxide.match("ος", in: os).map(\.path) == ["/Users/me/ΟΣ"])
        #expect(Zoxide.match("οσ", in: os).map(\.path) == [])
        let osa = [Zoxide.Folder(path: "/Users/me/ΟΣΑ", score: 40)]
        #expect(Zoxide.match("οσα", in: osa).map(\.path) == ["/Users/me/ΟΣΑ"])
        #expect(Zoxide.match("οςα", in: osa).map(\.path) == [])
    }
}

@Suite
struct ClipboardPopupTabToggleTests {
    @Test func tabTogglesClipboardAndAppsWithoutShiftTab() {
        var mode: ClipboardPopupMode = .clipboard

        mode = mode.afterTab(launcherEnabled: true)
        #expect(mode == .apps)

        mode = mode.afterTab(launcherEnabled: true)
        #expect(mode == .clipboard)

        // Shift-Tab does not toggle.
        #expect(mode.afterTab(shifted: true, launcherEnabled: true) == .clipboard)
        #expect(ClipboardPopupMode.apps.afterTab(shifted: true, launcherEnabled: true) == .apps)
    }

    @Test func disabledSettingStaysInClipboardMode() {
        #expect(ClipboardPopupMode.clipboard.afterTab(launcherEnabled: false) == .clipboard)
        #expect(ClipboardPopupMode.clipboard.afterTab(shifted: true, launcherEnabled: false) == .clipboard)
        #expect(ClipboardPopupMode.apps.afterTab(launcherEnabled: false) == .clipboard)
        #expect(ClipboardPopupMode.apps.toggled(launcherEnabled: false) == .clipboard)
    }

    @Test func sessionInvalidatesPriorTokensAcrossCloseAndReopen() {
        let session = LauncherSession()
        #expect(session.currentToken == nil)
        #expect(!session.isCurrent(0))

        let first = session.begin()
        #expect(session.currentToken == first)
        #expect(session.isCurrent(first))
        // Repeated begin while active keeps the same session token.
        #expect(session.begin() == first)

        // Closing or disabling invalidates the active token immediately.
        session.invalidate()
        #expect(session.currentToken == nil)
        #expect(!session.isCurrent(first))

        // Reopening issues a strictly newer token; old in-flight work stays rejected.
        let second = session.begin()
        #expect(second != first)
        #expect(!session.isCurrent(first))
        #expect(session.isCurrent(second))
    }

    @Test func keyPolicyScopesTabAndRowKeysToSearchAndPassesThroughControlsAndIME() {
        // Plain Tab toggles only when the search field has focus.
        #expect(ClipboardPopupKeyPolicy.decide(
            keyCode: ClipboardPopupKeyPolicy.tabKeyCode, hasShift: false,
            hasCommandOrControlOrOption: false, focus: .search, hasMarkedText: false
        ) == .toggleMode)
        #expect(ClipboardPopupKeyPolicy.decide(
            keyCode: ClipboardPopupKeyPolicy.tabKeyCode, hasShift: true,
            hasCommandOrControlOrOption: false, focus: .search, hasMarkedText: false
        ) == .passThroughWithoutRefocus)
        #expect(ClipboardPopupKeyPolicy.decide(
            keyCode: ClipboardPopupKeyPolicy.tabKeyCode, hasShift: false,
            hasCommandOrControlOrOption: false, focus: .control, hasMarkedText: false
        ) == .passThroughWithoutRefocus)

        // IME composition in the search field lets Tab, Return, Escape, and arrows reach the field editor.
        for code in [ClipboardPopupKeyPolicy.tabKeyCode, ClipboardPopupKeyPolicy.returnKeyCode,
                     ClipboardPopupKeyPolicy.escapeKeyCode, 125] {
            #expect(ClipboardPopupKeyPolicy.decide(
                keyCode: code, hasShift: false, hasCommandOrControlOrOption: false,
                focus: .search, hasMarkedText: true
            ) == .passThroughWithoutRefocus)
        }

        // Focused non-search controls keep Space, Return, Tab, and arrows without stealing focus back to search.
        for code in [ClipboardPopupKeyPolicy.spaceKeyCode, ClipboardPopupKeyPolicy.returnKeyCode,
                     ClipboardPopupKeyPolicy.keypadEnterKeyCode, ClipboardPopupKeyPolicy.tabKeyCode, 125, 126] {
            #expect(ClipboardPopupKeyPolicy.decide(
                keyCode: code, hasShift: false, hasCommandOrControlOrOption: false,
                focus: .control, hasMarkedText: false
            ) == .passThroughWithoutRefocus)
        }
        // Escape and Command shortcuts still reach the popup while a control is focused.
        #expect(ClipboardPopupKeyPolicy.decide(
            keyCode: ClipboardPopupKeyPolicy.escapeKeyCode, hasShift: false,
            hasCommandOrControlOrOption: false, focus: .control, hasMarkedText: false
        ) == .handlePopupKey)
        #expect(ClipboardPopupKeyPolicy.decide(
            keyCode: 40, hasShift: false,
            hasCommandOrControlOrOption: true, focus: .control, hasMarkedText: false
        ) == .handlePopupKey)
    }
}
