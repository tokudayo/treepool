#if os(macOS)
import AppKit
import SwiftUI

func treepoolSymbolImage(for appearance: NSAppearance) -> NSImage? {
    let variant = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? "Treepool-symbol-on-dark"
        : "Treepool-symbol-on-light"
    let url = Bundle.main.url(forResource: variant, withExtension: "png")
        ?? Bundle.module.url(forResource: variant, withExtension: "png")
    guard let url, let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 18, height: 18)
    image.accessibilityDescription = "Treepool"
    return image
}

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MenuStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverContent(store: store)
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Treepool"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        appearanceObserver = NSApp.observe(
            \.effectiveAppearance,
            options: [.initial, .new]
        ) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.statusItem?.button?.image = treepoolSymbolImage(
                    for: app.effectiveAppearance
                )
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover(sender)
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        monitorOutsideClicks()
        store.refresh()
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        removeOutsideClickMonitor()
    }

    private func monitorOutsideClicks() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover(nil) }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}
#endif
