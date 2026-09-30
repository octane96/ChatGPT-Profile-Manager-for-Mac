import AppKit

@MainActor
final class StatusPopoverDismissal: NSObject, NSPopoverDelegate {
    private weak var popover: NSPopover?
    private weak var statusButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(popover: NSPopover, statusButton: NSStatusBarButton) {
        self.popover = popover
        self.statusButton = statusButton
        super.init()
        popover.delegate = self
    }

    func popoverDidShow(_ notification: Notification) {
        stopMonitoring()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                self?.closeIfOutside(event)
            }
            // Dismissal must not swallow the click intended for another window.
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover?.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopMonitoring()
    }

    func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func closeIfOutside(_ event: NSEvent) {
        guard let popover, popover.isShown else { return }
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }
        // Let the status button's action handle toggling so one click cannot
        // close the popover here and immediately reopen it in the action.
        if let button = statusButton, let buttonWindow = button.window,
           event.window === buttonWindow,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
            return
        }
        popover.performClose(nil)
    }
}
