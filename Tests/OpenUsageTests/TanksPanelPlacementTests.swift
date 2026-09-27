import AppKit
import XCTest
@testable import OpenUsage

final class TanksPanelPlacementTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 1728, height: 1079)
    private let size = CGSize(width: 1040, height: 573)

    func testFirstOpenPinsToLeftEdgeUnderMenuBar() {
        let origin = TanksPanelPlacement.origin(saved: nil, size: size, visibleFrame: visible, menuBarBottom: 1079)

        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 1079 - PanelGeometry.topGap - 573)
    }

    func testSavedOriginIsKept() {
        let origin = TanksPanelPlacement.origin(saved: NSPoint(x: 300, y: 200), size: size, visibleFrame: visible, menuBarBottom: 1079)

        XCTAssertEqual(origin, NSPoint(x: 300, y: 200))
    }

    func testSavedOriginOffScreenIsPulledBack() {
        let origin = TanksPanelPlacement.origin(saved: NSPoint(x: 1500, y: -400), size: size, visibleFrame: visible, menuBarBottom: 1079)

        XCTAssertEqual(origin.x, 1728 - 1040)
        XCTAssertEqual(origin.y, 0)
    }

    func testSecondaryDisplayOffsetIsHonoured() {
        let secondary = NSRect(x: -2560, y: 200, width: 2560, height: 1415)
        let origin = TanksPanelPlacement.origin(saved: nil, size: size, visibleFrame: secondary, menuBarBottom: 1615)

        XCTAssertEqual(origin.x, -2560)
        XCTAssertEqual(origin.y, 1615 - PanelGeometry.topGap - 573)
    }

    func testRoundTripThroughDefaults() {
        let defaults = UserDefaults(suiteName: "TanksPanelPlacementTests")!
        defaults.removePersistentDomain(forName: "TanksPanelPlacementTests")
        XCTAssertNil(TanksPanelPlacement.load(from: defaults))

        TanksPanelPlacement.save(NSPoint(x: 12.5, y: 34), to: defaults)
        XCTAssertEqual(TanksPanelPlacement.load(from: defaults), NSPoint(x: 12.5, y: 34))

        TanksPanelPlacement.reset(in: defaults)
        XCTAssertNil(TanksPanelPlacement.load(from: defaults))
    }
}
