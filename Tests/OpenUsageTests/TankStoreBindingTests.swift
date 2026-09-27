import Foundation
import XCTest
@testable import OpenUsage

final class TankStoreBindingTests: XCTestCase {
    private func projection(_ key: String, fill: Double, projected: Double? = nil, crossesIn: TimeInterval? = nil, format: TankFormat = .percent, isPaid: Bool = false) -> TankProjection {
        let tank = Tank(key: key, label: key, used: fill * 100, limit: 100, format: format, isPaid: isPaid)
        return TankProjection(
            tank: tank,
            ratePerHour: nil,
            projectedAtReset: projected.map { $0 * 100 },
            crossesAt: crossesIn.map { Date(timeIntervalSince1970: 1_000_000 + $0) },
            tier: .green
        )
    }

    func testEarliestCrossingWinsOverHigherFill() {
        let soon = projection("5-hour", fill: 0.60, crossesIn: 600)
        let later = projection("week", fill: 0.90, crossesIn: 7200)
        let full = projection("month", fill: 0.99)

        XCTAssertEqual(TankStore.binding(among: [full, later, soon])?.tank.key, "5-hour")
    }

    func testWithoutCrossingHighestProjectedFillWins() {
        let flat = projection("week", fill: 0.70)
        let climbing = projection("5-hour", fill: 0.40, projected: 0.95)

        XCTAssertEqual(TankStore.binding(among: [flat, climbing])?.tank.key, "5-hour")
    }

    func testCreditTanksCountAndDollarAndPaidTanksDoNot() {
        let credits = projection("month", fill: 0.99, format: .credits)
        let dollars = projection("spend", fill: 1.0, format: .dollars)
        let paid = projection("extra", fill: 1.0, isPaid: true)
        let percent = projection("week", fill: 0.20)

        XCTAssertEqual(TankStore.binding(among: [percent, dollars, paid, credits])?.tank.key, "month")
    }

    func testEmptyWhenNothingIsCapped() {
        XCTAssertNil(TankStore.binding(among: [projection("spend", fill: 0.5, format: .dollars)]))
    }
}
