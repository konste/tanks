import AppKit
import SwiftUI

/// The status item and the fixed-size panel that hosts `TanksDashboardView`. Same panel class and
/// outside-click monitor as upstream's controller; no height morphing, no transparency modes, the
/// appearance follows the system.
@MainActor
final class TanksStatusItemController: NSObject {
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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
