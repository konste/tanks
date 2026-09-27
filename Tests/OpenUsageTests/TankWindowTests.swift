import Foundation
import XCTest
@testable import OpenUsage

/// The `start – end` window text under a bar, and where the start comes from.
final class TankWindowTests: XCTestCase {
    private var cal: Calendar { Calendar.current }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testSameDayWindowShowsTimesOnly() {
        XCTAssertEqual(Fmt.window(date(2026, 9, 26, 16, 30), date(2026, 9, 26, 21, 30)), "16:30 – 21:30")
    }

    func testWindowAcrossMidnightShowsWeekdays() {
        XCTAssertEqual(Fmt.window(date(2026, 9, 26, 22, 0), date(2026, 9, 27, 3, 0)), "Sat 22:00 – Sun 03:00")
    }

    func testSameMonthWindowRepeatsOnlyTheDay() {
        XCTAssertEqual(Fmt.window(date(2026, 9, 20, 20, 59), date(2026, 9, 27, 20, 59)), "Sep 20 – 27 20:59")
    }

    func testCrossMonthWindowNamesBothMonths() {
        XCTAssertEqual(Fmt.window(date(2026, 9, 1, 11, 24), date(2026, 10, 1, 11, 24)), "Sep 1 – Oct 1 11:24")
    }

    func testWindowWithDifferentTimesOfDayPrintsBoth() {
        XCTAssertEqual(Fmt.window(date(2026, 9, 1, 11, 24), date(2026, 10, 1, 9, 0)), "Sep 1 11:24 – Oct 1 09:00")
    }

    func testWindowStartIsStatedOrDerived() {
        let reset = date(2026, 10, 1, 11, 24)
        let stated = Tank(key: "auto", label: "cursor models", used: 13, limit: 100, format: .percent,
                          resetsAt: reset, periodSeconds: 30 * 86400, startsAt: date(2026, 9, 1, 11, 24))
        XCTAssertEqual(stated.windowStart, date(2026, 9, 1, 11, 24))

        let rolling = Tank(key: "week", label: "week", used: 28, limit: 100, format: .percent,
                           resetsAt: reset, periodSeconds: 7 * 86400)
        XCTAssertEqual(rolling.windowStart, reset.addingTimeInterval(-7 * 86400))

        let noReset = Tank(key: "credits", label: "credits (paid)", used: 1, limit: 50, format: .dollars, isPaid: true)
        XCTAssertNil(noReset.windowStart)
    }

    func testCursorRowsMapToTheDashboardPools() {
        let rows = CursorAdminFeed.parse([
            "subscriptionCycleStart": 1_788_287_074_000,
            "teamMemberSpend": [[
                "email": "k@example.com", "spendCents": 12942.1, "includedSpendCents": 23288.2,
                "autoPercentUsed": 13.2, "apiPercentUsed": 46.9, "totalPercentUsed": 18.6,
                "billingTier": "TIER_2000", "hardLimitOverrideDollars": 0,
            ]],
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].autoPercent, 13.2)
        XCTAssertEqual(rows[0].apiPercent, 46.9)
        XCTAssertEqual(rows[0].spendCents, 12942.1)
        XCTAssertNil(rows[0].limitDollars)
        XCTAssertEqual(rows[0].cycleStart, Date(timeIntervalSince1970: 1_788_287_074))
    }
}
