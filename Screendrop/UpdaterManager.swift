//
//  UpdaterManager.swift
//  Screendrop
//

import AppKit
import Combine
import Observation
import Sparkle
import SwiftUI

/// Sparkle updates from this project's feed (`SUFeedURL`), signed with the key
/// in `SUPublicEDKey`. Automatic checks are opt-in: Info.plist leaves
/// `SUEnableAutomaticChecks` unset, so Sparkle asks on the second launch, and
/// Settings › About can change the answer later.
@Observable
final class UpdaterManager: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdaterManager()

    /// The released app only. Debug builds, Sukusho Dev and test builds under
    /// other bundle IDs never check, or a release could replace them.
    static let updatesThisBuild: Bool = {
        #if DEBUG
        false
        #else
        Bundle.main.bundleIdentifier == "com.tommyent.Sukusho"
        #endif
    }()

    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckSubscription: AnyCancellable?
    @ObservationIgnored private var showsDockIcon = false

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        canCheckSubscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func start() {
        guard Self.updatesThisBuild else { return }
        LegacyIdentityImport.clearImportedSparkleKeysOnce(in: .standard)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard Self.updatesThisBuild else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Sukusho often runs with no Dock icon, which Sparkle expects to be told about.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The Dock icon comes back while an update is on screen, so the update
    /// window can be found again with ⌘-Tab. Only a check the person started
    /// brings Sukusho to the front.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !showsDockIcon else { return }
        showsDockIcon = true
        AppActivationPolicy.enter(activate: state.userInitiated)
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard showsDockIcon else { return }
        showsDockIcon = false
        AppActivationPolicy.leave()
    }
}

/// Sukusho › Check for Updates…, under About.
struct CheckForUpdatesCommand: View {
    var body: some View {
        Button("Check for Updates…") { UpdaterManager.shared.checkForUpdates() }
            .disabled(!UpdaterManager.shared.canCheckForUpdates)
    }
}
