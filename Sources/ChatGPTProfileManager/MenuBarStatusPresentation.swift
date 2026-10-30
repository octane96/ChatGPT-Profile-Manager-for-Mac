import AppKit

/// Owns visual updates only; usage fetching and profile selection remain with
/// AppDelegate. Metadata can change without invalidating the text's layout.
@MainActor
final class MenuBarStatusPresentation: NSObject {
    private weak var statusItem: NSStatusItem?
    private let icon: NSImage
    let usageLabel: MenuBarUsageLabel
    private var showsUsage = false
    private var lastToolTip: String?
    private var lastAccessibilityValue: String?

    init(
        statusItem: NSStatusItem,
        icon: NSImage,
        usageLabel: MenuBarUsageLabel = MenuBarUsageLabel()
    ) {
        self.statusItem = statusItem
        self.icon = icon
        self.usageLabel = usageLabel
        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.font = nil
            button.alignment = .center
            button.image = icon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            usageLabel.isHidden = true
            button.addSubview(usageLabel)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func showUsage(title: String, toolTip: String, accessibilityValue: String) {
        guard let button = statusItem?.button else { return }
        if !showsUsage {
            showsUsage = true
            button.image = nil
            // Keep the native cell in the same layout mode for both content
            // types. With a nil image and empty title only usageLabel is shown.
            button.imagePosition = .imageOnly
        }
        usageLabel.updateText(title)
        updateUsageLength()
        if usageLabel.isHidden { usageLabel.isHidden = false }
        updateMetadata(toolTip: toolTip, accessibilityValue: accessibilityValue)
    }

    func showIcon(toolTip: String) {
        guard let button = statusItem?.button else { return }
        if showsUsage {
            showsUsage = false
            usageLabel.isHidden = true
            button.image = icon
            button.imagePosition = .imageOnly
        }
        setLengthIfChanged(NSStatusItem.variableLength)
        updateMetadata(toolTip: toolTip, accessibilityValue: nil)
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(self)
        usageLabel.removeFromSuperview()
        statusItem = nil
    }

    @objc
    private func screenParametersDidChange() {
        if showsUsage { updateUsageLength() }
    }

    private func updateUsageLength() {
        setLengthIfChanged(max(NSStatusBar.system.thickness, usageLabel.preferredWidth))
    }

    private func setLengthIfChanged(_ length: CGFloat) {
        guard let statusItem, statusItem.length != length else { return }
        statusItem.length = length
    }

    private func updateMetadata(toolTip: String, accessibilityValue: String?) {
        guard let button = statusItem?.button else { return }
        if lastToolTip != toolTip {
            lastToolTip = toolTip
            button.toolTip = toolTip
        }
        if lastAccessibilityValue != accessibilityValue {
            lastAccessibilityValue = accessibilityValue
            button.setAccessibilityValue(accessibilityValue)
        }
    }
}
