import Foundation

/// Posts one macOS notification per advice key for the rules that ask for it (switch now, credits
/// guard). The key carries the window stamp, so the same condition in the next window notifies
/// again and a repeat within the window stays quiet.
@MainActor
final class TanksNotifier {
    private var posted: Set<String> = []
    private let post: @MainActor (Advice) async -> Bool

    init(post: @escaping @MainActor (Advice) async -> Bool = TanksNotifier.systemPost) {
        self.post = post
    }

    func consider(_ advice: [Advice]) {
        for item in advice where item.notifies && !posted.contains(item.key) {
            posted.insert(item.key)
            Task { [post] in
                if await !post(item) {
                    // Delivery failed (not authorized yet): allow a retry on the next pass.
                    await MainActor.run { _ = self.posted.remove(item.key) }
                }
            }
        }
        // Forget keys whose advice has cleared, bounded so the set never grows unboundedly.
        if posted.count > 200 {
            let live = Set(advice.map(\.key))
            posted = posted.intersection(live)
        }
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
