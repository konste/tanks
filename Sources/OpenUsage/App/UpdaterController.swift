import AppKit
import Foundation
import Observation

/// Tanks ships no auto-updater: it is a personal fork built and installed from source, so this is a
/// dormant stand-in that keeps the Settings and dashboard call sites compiling. `isActive` stays false,
/// which hides the Updates section and the update banner exactly as OpenUsage's own dev build does.
@MainActor
@Observable
final class UpdaterController {
    static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    private let presentationController: UpdaterPresentationController

    private(set) var isActive = false
    private(set) var canCheckForUpdates = false
    private(set) var availableUpdateVersion: String?

    var betaChannelEnabled: Bool {
        didSet { UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey) }
    }

    var automaticallyChecksForUpdates = false

    init(presentationController: UpdaterPresentationController = UpdaterPresentationController()) {
        self.presentationController = presentationController
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
    }

    func start() {
        AppLog.info(.updates, "disabled: Tanks has no update feed")
    }

    func resetToDefaults() {
        betaChannelEnabled = false
        automaticallyChecksForUpdates = true
    }

    func checkForUpdates() {}
    func installAvailableUpdate() {}
    func dismissAvailableUpdate() { availableUpdateVersion = nil }
}

/// Owns the narrow AppKit boundary required to present Sparkle from a dockless menu-bar app.
///
/// `NSApplication.activate()` is unreliable when another app is active (sparkle-project/Sparkle#2889),
/// so user-initiated update UI deliberately uses the older API that ignores the current foreground app.
/// The injected closures keep that behavior unit-testable without trying to automate macOS focus.
@MainActor
final class UpdaterPresentationController {
    private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let isActive: @MainActor () -> Bool
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let activate: @MainActor (Bool) -> Void

    convenience init(application: NSApplication = .shared) {
        self.init(
            activationPolicy: { application.activationPolicy() },
            isActive: { application.isActive },
            setActivationPolicy: { application.setActivationPolicy($0) },
            activate: { application.activate(ignoringOtherApps: $0) }
        )
    }

    init(
        activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        isActive: @escaping @MainActor () -> Bool,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        activate: @escaping @MainActor (Bool) -> Void
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
    }

    func bringToFront(reason: String) {
        let beforePolicy = activationPolicy()
        let beforeActive = isActive()
        let policyChanged = setActivationPolicy(.regular)
        activate(true)
        AppLog.info(
            .updates,
            "foreground updater (reason=\(reason), policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(beforeActive)->\(isActive()), policyChanged=\(policyChanged))"
        )
    }

    func returnToMenuBar() {
        let beforePolicy = activationPolicy()
        let policyChanged = setActivationPolicy(.accessory)
        AppLog.info(
            .updates,
            "finish updater presentation (policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(isActive()), policyChanged=\(policyChanged))"
        )
    }
}
