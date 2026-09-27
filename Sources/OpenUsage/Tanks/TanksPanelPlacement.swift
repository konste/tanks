import AppKit

/// Where the panel opens. First open: pinned to the left edge of the screen that holds the status
/// item, just under the menu bar (his ask, 2026-09-26: "initial position should be moved all the
/// way to the left"). Once dragged, the panel reopens where it was left, pulled back on screen if
/// the display layout changed underneath it.
enum TanksPanelPlacement {
    static let originKey = "tanks.panelOrigin"

    /// Bottom-left origin for a panel of `size` on `visibleFrame`. `saved` is the origin from the
    /// last drag, or nil before the first one; `menuBarBottom` is the y of the menu bar's lower
    /// edge in screen coordinates (the default top of the panel, with `PanelGeometry.topGap`).
    static func origin(saved: NSPoint?, size: CGSize, visibleFrame: NSRect, menuBarBottom: CGFloat) -> NSPoint {
        let proposed = saved ?? NSPoint(x: visibleFrame.minX, y: menuBarBottom - PanelGeometry.topGap - size.height)
        return clamped(proposed, size: size, visibleFrame: visibleFrame)
    }

    static func clamped(_ origin: NSPoint, size: CGSize, visibleFrame: NSRect) -> NSPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> NSPoint? {
        guard let pair = defaults.array(forKey: originKey) as? [Double], pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    static func save(_ origin: NSPoint, to defaults: UserDefaults = .standard) {
        defaults.set([origin.x, origin.y], forKey: originKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: originKey)
    }
}
