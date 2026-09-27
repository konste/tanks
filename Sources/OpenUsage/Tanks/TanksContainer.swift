import Foundation
import Observation

/// Composition root for Tanks: config, the six sources, the store, notifications, the state
/// writer and the switch actions. Injected into the SwiftUI environment as one object.
@MainActor
@Observable
final class TanksContainer {
    let config: TanksConfig
    let store: TankStore
    let actions: SwitchActions
    /// The macOS login item for this bundle; seeded on first live launch, switchable in the footer.
    let launchAtLogin = LaunchAtLoginSetting()
    /// Set by `TanksStatusItemController` to its `hidePanel`; the header's close button and the
    /// panel's Esc key both call this rather than reaching for AppKit themselves.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// The last switch outcome, shown in the header for a while.
    private(set) var notice: String?

    @ObservationIgnored private let notifier = TanksContainer.makeNotifier()

    /// Snapshot instances render and exit: they never post (each one used to re-post every alert)
    /// and they claim keys in a scratch suite, so fixture keys never silence a live alert.
    private static func makeNotifier() -> TanksNotifier {
        guard TanksSnapshot.isRequested else { return TanksNotifier() }
        let suite = "dev.konste.tanks.snapshot"
        let scratch = UserDefaults(suiteName: suite) ?? .standard
        scratch.removePersistentDomain(forName: suite)
        return TanksNotifier(post: TanksNotifier.silentPost, defaults: scratch)
    }
    @ObservationIgnored private let writer: TanksStateWriter
    @ObservationIgnored private var reprojectTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(config: TanksConfig = TanksConfig.load()) {
        self.config = config
        let cursorFeed = CursorAdminFeed(keychainService: config.cursorAdminKeyKeychainService)
        var sources: [TankSource] = []
        for slot in AccountSlot.allCases {
            sources.append(ClaudeTankSource(account: config.account(TankAccountID(vendor: .claude, slot: slot)), config: config))
        }
        for slot in AccountSlot.allCases {
            sources.append(CodexTankSource(account: config.account(TankAccountID(vendor: .codex, slot: slot)), config: config))
        }
        for slot in AccountSlot.allCases {
            sources.append(CursorTankSource(account: config.account(TankAccountID(vendor: .cursor, slot: slot)), config: config, feed: cursorFeed))
        }
        self.store = TankStore(config: config, sources: sources)
        self.actions = SwitchActions(config: config)
        self.writer = TanksStateWriter(config: config)

        store.onAdvice = { [notifier] advice in notifier.consider(advice) }
        store.onStates = { [writer, store] states in
            let advice = store.visibleAdvice
            Task.detached(priority: .utility) { writer.write(states, advice: advice) }
        }
        AppNotifications.shared.registerAsDelegate()
        AppNotifications.shared.requestAuthorization()
        TanksLaunchAtLogin.seedOnce(launchAtLogin)
        store.start()
        reprojectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.store.reproject()
            }
        }
    }

    var headerMeta: String {
        if let notice { return notice }
        let cadence = "polls \(Int(config.pollInterval)) s · Claude \(Int(config.claudePollInterval)) s · idle \(Int(config.idlePollInterval / 60)) min"
        guard let tick = store.lastTick else { return cadence }
        let live = store.states.values.filter { $0.reading?.isLive ?? false }.count
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "\(f.string(from: tick)) · \(cadence) · \(live) of \(store.states.count) fresh"
    }

    func requestClose() {
        onRequestClose?()
    }

    func performSwitch(to id: TankAccountID) {
        let actions = actions
        show("switching to \(config.account(id).label)…", for: 120)
        Task { [weak self] in
            let outcome = await actions.switchTo(id)
            let text: String
            switch outcome {
            case .started(let m), .done(let m): text = m
            case .unsupported(let m), .failed(let m): text = "✗ \(m)"
            }
            AppLog.info(.lifecycle, "switch \(id): \(text)")
            self?.show(text, for: 20)
            self?.store.refreshAll()
        }
    }

    private func show(_ text: String, for seconds: TimeInterval) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
