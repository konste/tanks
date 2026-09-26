import AppKit
import SwiftUI

/// The status item and the fixed-size panel that hosts `TanksDashboardView`. Same panel class and
/// outside-click monitor as upstream's controller; no height morphing, no transparency modes, the
/// appearance follows the system.
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
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil

        let content = NSView()
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
        let worst = store.worstActiveProjection
        let stale = store.states.values.filter(\.isActive).contains { !($0.reading?.isLive ?? false) }
        return TanksMenuBarRenderer.Content(
            fill: worst.map { $0.projectedFill ?? $0.fill },
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
        let topLeft = PanelGeometry.clampedTopLeft(below: buttonRect, width: TanksDashboardView.size.width, visibleFrame: screen?.visibleFrame)
        panel.setFrame(PanelGeometry.frame(topLeft: topLeft, width: TanksDashboardView.size.width, height: TanksDashboardView.size.height), display: false)
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
