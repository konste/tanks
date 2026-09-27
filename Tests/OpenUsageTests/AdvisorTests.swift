import Foundation
import XCTest
@testable import OpenUsage

final class AdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ slot: AccountSlot) -> TankAccount {
        TankAccount(id: TankAccountID(vendor: .claude, slot: slot), email: "\(slot.rawValue)@example.com")
    }

    private func projection(_ key: String, fill: Double) -> TankProjection {
        let tank = Tank(key: key, label: key, used: fill * 100, limit: 100, format: .percent, resetsAt: now.addingTimeInterval(3600), periodSeconds: 5 * 3600)
        return TankProjection(tank: tank, ratePerHour: nil, projectedAtReset: nil, crossesAt: nil, tier: .green)
    }

    private func assessment(_ slot: AccountSlot, active: Bool, fiveHour: Double, week: Double) -> AccountAssessment {
        AccountAssessment(account: account(slot), isActive: active, reading: nil, projections: [
            projection("5-hour", fill: fiveHour),
            projection("week", fill: week),
        ])
    }

    func testNoSwitchWhenTheOtherAccountsWeekIsFull() {
        let advice = Advisor.advise([
            assessment(.primary, active: true, fiveHour: 1.0, week: 0.28),
            assessment(.secondary, active: false, fiveHour: 0.0, week: 1.0),
        ], now: now)

        let fiveHour = advice.first { $0.key.hasPrefix("runs-dry:claude/primary:5-hour") }
        XCTAssertNotNil(fiveHour, "\(advice.map(\.key))")
        XCTAssertNil(advice.first { $0.key.hasPrefix("switch-now:") })
        XCTAssertTrue(fiveHour?.text.contains("but its week at 100%") ?? false, fiveHour?.text ?? "")
        XCTAssertTrue(fiveHour?.text.hasSuffix("No headroom on the other account.") ?? false)
    }

    func testSwitchWhenEveryWindowOnTheOtherAccountIsUsable() {
        let advice = Advisor.advise([
            assessment(.primary, active: true, fiveHour: 1.0, week: 0.28),
            assessment(.secondary, active: false, fiveHour: 0.0, week: 0.40),
        ], now: now)

        let switchNow = advice.first { $0.key.hasPrefix("switch-now:claude/primary:5-hour") }
        XCTAssertNotNil(switchNow, "\(advice.map(\.key))")
        XCTAssertEqual(switchNow?.action, .switchTo(TankAccountID(vendor: .claude, slot: .secondary)))
    }

    func testWindowStampIgnoresSecondLevelDrift() {
        func tank(_ reset: Double) -> Tank {
            Tank(key: "month", label: "month", used: 0, limit: 100, format: .percent, resetsAt: Date(timeIntervalSince1970: reset))
        }

        XCTAssertEqual(Fmt.windowStamp(tank(1790812800)), Fmt.windowStamp(tank(1790812801)))
        XCTAssertEqual(Fmt.windowStamp(tank(1790812800)), "1790812800")
        XCTAssertNotEqual(Fmt.windowStamp(tank(1790812800)), Fmt.windowStamp(tank(1790812800 + 3600)))
        XCTAssertEqual(Fmt.windowStamp(Tank(key: "c", label: "c", used: 0, limit: 0, format: .dollars)), "-")
    }

    func testBlockingWindowIsTheFullestOtherWindow() {
        let other = assessment(.secondary, active: false, fiveHour: 0.95, week: 0.92)

        XCTAssertEqual(Advisor.blockingWindow(on: other, except: "5-hour")?.tank.key, "week")
        XCTAssertEqual(Advisor.blockingWindow(on: other, except: "week")?.tank.key, "5-hour")
        XCTAssertNil(Advisor.blockingWindow(on: assessment(.secondary, active: false, fiveHour: 0.5, week: 0.5), except: "5-hour"))
    }
}
