import AppKit
import SwiftUI

/// The status item and the fixed-size panel that hosts `TanksDashboardView`. Same panel class and
/// outside-click monitor as upstream's controller; no height morphing, no transparency modes, the
/// appearance follows the system. The panel is draggable by its background (the header carries a
/// drag gesture too, for the areas SwiftUI claims) and reopens where it was last dragged; see
/// `TanksPanelPlacement` for the first-open position.
@MainActor
final class TanksStatusItemController: NSObject {
    private static let autosaveName = "tanks"
    /// Points from the right edge of the status area. The rightmost ~240 pt belong to the clock,
    /// Control Center and battery, and anything sorted past them is clipped; a smaller number
    /// than this lands there. With a menu-bar manager such as Ice the visible section sits just
    /// left of its chevron (~250 pt on a 16" MacBook Pro), so 300 keeps the tank in view.
    private static let preferredPositionFromRight = 300.0

    private let container: TanksContainer
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hosting: NSHostingController<AnyView>
    private var lastImage: NSImage?
    /// Set while `showPanel` positions the panel itself, so that move is not saved as a drag.
    private var isPositioning = false
    private var moveObserver: NSObjectProtocol?
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { false },
        onInsidePanelClick: {},
        onDismiss: { [weak self] in self?.hidePanel() }
    )

    init(container: TanksContainer) {
        self.container = container
        // A new status item starts at the far left of the status area, which a menu-bar manager
        // (Ice, Bartender) treats as its hidden section, and a notched display drops outright once
        // the bar is full. Claim a slot near the system items on first launch so the tank is seen;
        // a position the user later drags to (⌘-drag) is kept by the autosave.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(Self.preferredPositionFromRight, forKey: positionKey)
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = Self.autosaveName
        self.hosting = NSHostingController(rootView: AnyView(TanksDashboardView().environment(container)))
        self.panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: TanksDashboardView.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateImage()
        MenuBarPopover.dismissHandler = { [weak self] in self?.hidePanel() }
        MenuBarPopover.showHandler = { [weak self] in self?.showPanel() }
        AppLog.info(.statusItem, "Tanks status item ready")
        // Control Center (the status bar host) keeps per-bundle state in memory; after a burst of
        // short-lived instances of this bundle id it once stopped placing the item at all (the
        // button's window stayed at its unplaced origin). Log the placement so that state is
        // visible in the log instead of only in the missing icon; `killall ControlCenter` clears it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let window = self.statusItem.button?.window else { return }
            let rect = NSStringFromRect(window.frame)
            if window.frame.origin.x > 0 || window.frame.origin.y > 0 {
                AppLog.info(.statusItem, "status item placed at \(rect)")
            } else {
                AppLog.warn(.statusItem, "status item NOT placed by Control Center (\(rect)); killall ControlCenter clears it")
            }
        }
    }

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil

        let content = DraggableContentView()
        let host = hosting.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.cornerRadius = 13
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let root = NSViewController()
        root.view = content
        root.addChild(hosting)
        panel.contentViewController = root

        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPositioning, self.panel.isVisible else { return }
                TanksPanelPlacement.save(self.panel.frame.origin)
            }
        }
    }

    /// Lets a mouse-down that no SwiftUI control claims start a window drag.
    private final class DraggableContentView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    // MARK: - Menu bar image

    /// Renders the strip and re-arms on the next store change (`withObservationTracking` is one-shot).
    private func updateImage() {
        let content = withObservationTracking {
            menuBarContent()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.updateImage()
            }
        }
        let image = TanksMenuBarRenderer.image(for: content)
        guard image !== lastImage else { return }
        lastImage = image
        statusItem.button?.image = image
    }

    private func menuBarContent() -> TanksMenuBarRenderer.Content {
        let store = container.store
        let binding = store.bindingProjection
        let stale = store.states.values.filter(\.isActive).contains { !($0.reading?.isLive ?? false) }
        return TanksMenuBarRenderer.Content(
            fill: binding?.fill,
            attention: store.attention,
            stale: stale
        )
    }

    // MARK: - Show / hide

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showContextMenu() {
        if panel.isVisible { hidePanel() }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Refresh", systemSymbol: "arrow.clockwise", keyEquivalent: "r") { [weak self] in
            self?.container.store.refreshAll()
        })
        menu.addItem(ClosureMenuItem(title: "Reset Panel Position", systemSymbol: "arrow.uturn.backward", keyEquivalent: "") {
            TanksPanelPlacement.reset()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Tanks", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: TanksDashboardView.size)
        let origin = TanksPanelPlacement.origin(
            saved: TanksPanelPlacement.load(),
            size: TanksDashboardView.size,
            visibleFrame: visible,
            menuBarBottom: buttonRect.minY
        )
        isPositioning = true
        panel.setFrame(NSRect(origin: origin, size: TanksDashboardView.size), display: false)
        isPositioning = false
        container.store.reproject()
        hosting.view.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
    }
}
