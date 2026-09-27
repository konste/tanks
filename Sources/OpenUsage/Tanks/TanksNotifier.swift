import Foundation

/// Posts one macOS notification per advice key for the rules that ask for it (switch now, credits
/// guard). The key carries the window stamp, so the same condition in the next window notifies
/// again and a repeat within the window stays quiet.
///
/// The posted keys persist in UserDefaults: on 2026-09-26 every relaunch (and every headless
/// snapshot instance) re-posted the same "Codex month at 99%" banner, nine copies in ten minutes.
/// A key is forgotten once its window stamp is in the past; a key without a window (the credits
/// guard, stamp "-") is forgotten after `unstampedTTL`, so that one can speak again next day.
@MainActor
final class TanksNotifier {
    static let postedKey = "tanks.notifiedAdviceKeys"
    static let unstampedTTL: TimeInterval = 24 * 3600

    /// Advice key → unix time it was posted.
    private var posted: [String: Double]
    private let post: @MainActor (Advice) async -> Bool
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        post: @escaping @MainActor (Advice) async -> Bool = TanksNotifier.systemPost,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.post = post
        self.defaults = defaults
        self.now = now
        self.posted = defaults.dictionary(forKey: Self.postedKey) as? [String: Double] ?? [:]
    }

    /// A post function for instances that must stay silent (headless snapshots): claims the key
    /// without touching Notification Center.
    static let silentPost: @MainActor (Advice) async -> Bool = { _ in true }

    func consider(_ advice: [Advice]) {
        for item in advice where item.notifies && posted[item.key] == nil {
            posted[item.key] = now().timeIntervalSince1970
            persist()
            Task { [post] in
                if await !post(item) {
                    // Delivery failed (not authorized yet): allow a retry on the next pass.
                    await MainActor.run {
                        self.posted[item.key] = nil
                        self.persist()
                    }
                }
            }
        }
        expire()
    }

    /// Drops keys whose window has reset (the stamp is the reset's unix time) and unstamped keys
    /// older than `unstampedTTL`; those can never match a live advice again, or should not
    /// silence it forever.
    private func expire() {
        let current = now().timeIntervalSince1970
        let before = posted.count
        posted = posted.filter { key, postedAt in
            if let stamp = key.split(separator: ":").last, let reset = Double(stamp) {
                return reset > current
            }
            return current - postedAt < Self.unstampedTTL
        }
        if posted.count != before { persist() }
    }

    private func persist() {
        defaults.set(posted, forKey: Self.postedKey)
    }

    static func systemPost(_ advice: Advice) async -> Bool {
        await AppNotifications.shared.post(
            idPrefix: advice.key,
            title: advice.severity == .alert ? "Tanks — switch now" : "Tanks",
            subtitle: advice.vendor.rawValue.capitalized,
            body: advice.text
        )
    }
}
