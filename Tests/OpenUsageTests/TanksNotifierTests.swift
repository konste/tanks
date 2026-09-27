import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TanksNotifierTests: XCTestCase {
    private let suite = "TanksNotifierTests"

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func advice(_ key: String, notifies: Bool = true) -> Advice {
        Advice(key: key, severity: .alert, vendor: .codex, text: key, notifies: notifies)
    }

    private func at(_ seconds: Double) -> () -> Date {
        { Date(timeIntervalSince1970: seconds) }
    }

    func testSameKeyPostsOncePerProcess() async {
        let defaults = freshDefaults()
        var posts: [String] = []
        let notifier = TanksNotifier(post: { posts.append($0.key); return true }, defaults: defaults, now: at(1000))
        let item = advice("runs-dry:codex/primary:month:2000")

        notifier.consider([item])
        notifier.consider([item])
        await Task.yield()

        XCTAssertEqual(posts, [item.key])
    }

    func testPostedKeysSurviveRelaunch() async {
        let defaults = freshDefaults()
        let item = advice("runs-dry:codex/primary:month:2000")
        let first = TanksNotifier(post: { _ in true }, defaults: defaults, now: at(1000))
        first.consider([item])
        await Task.yield()

        var posts: [String] = []
        let second = TanksNotifier(post: { posts.append($0.key); return true }, defaults: defaults, now: at(1000))
        second.consider([item])
        await Task.yield()

        XCTAssertEqual(posts, [])
    }

    func testKeyExpiresWithItsWindow() async {
        let defaults = freshDefaults()
        let item = advice("runs-dry:codex/primary:month:2000")
        let first = TanksNotifier(post: { _ in true }, defaults: defaults, now: at(1000))
        first.consider([item])
        await Task.yield()

        var posts: [String] = []
        let later = TanksNotifier(post: { posts.append($0.key); return true }, defaults: defaults, now: at(3000))
        later.consider([])
        XCTAssertEqual(defaults.dictionary(forKey: TanksNotifier.postedKey)?.count, 0)
        later.consider([item])
        await Task.yield()

        XCTAssertEqual(posts, [item.key])
    }

    func testUnstampedKeyExpiresAfterADay() async {
        let defaults = freshDefaults()
        let item = advice("credits:claude/primary:credits:-")
        let first = TanksNotifier(post: { _ in true }, defaults: defaults, now: at(1000))
        first.consider([item])
        await Task.yield()

        var posts: [String] = []
        let sameDay = TanksNotifier(post: { posts.append($0.key); return true }, defaults: defaults, now: at(1000 + 12 * 3600))
        sameDay.consider([item])
        await Task.yield()
        XCTAssertEqual(posts, [])

        let nextDay = TanksNotifier(post: { posts.append($0.key); return true }, defaults: defaults, now: at(1000 + 25 * 3600))
        nextDay.consider([item])
        await Task.yield()
        XCTAssertEqual(posts, [item.key])
    }

    func testSilentPostClaimsWithoutPosting() async {
        let defaults = freshDefaults()
        let notifier = TanksNotifier(post: TanksNotifier.silentPost, defaults: defaults, now: at(1000))
        notifier.consider([advice("runs-dry:codex/primary:month:2000")])
        await Task.yield()

        XCTAssertEqual(defaults.dictionary(forKey: TanksNotifier.postedKey)?.keys.sorted(), ["runs-dry:codex/primary:month:2000"])
    }
}
