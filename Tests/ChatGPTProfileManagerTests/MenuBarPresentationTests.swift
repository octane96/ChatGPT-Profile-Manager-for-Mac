import AppKit
import XCTest
@testable import ChatGPTProfileManager

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    private let titles = [
        "5h 0%\nW 9%", "5h 9%\nW 10%", "5h 99%\nW 100%",
        "5h 100%\nW 100%", "5h —\nW 67%", "5h 90%\nW —", "—"
    ]

    func testUsageFitsMenuBarHeightsWithoutShrinkingFont() throws {
        for height in [22.0, 24.0, 26.0, 37.0] {
            let parent = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: height))
            let label = MenuBarUsageLabel()
            parent.addSubview(label)
            for title in titles {
                let width = label.updateText(title)
                parent.setFrameSize(NSSize(width: max(height, width), height: height))

                XCTAssertEqual(label.stringValue, title)
                XCTAssertTrue(parent.bounds.contains(label.frame), "\(height): \(title)")
                XCTAssertEqual(label.frame.midY, parent.bounds.midY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(label.frame.width, label.preferredWidth)
                let font = try XCTUnwrap(label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, 10)
            }
        }
    }

    func testIdenticalUsageDoesNotReassignTextOrFrame() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 37))
        let label = RecordingUsageLabel()
        parent.addSubview(label)
        let width = label.updateText("5h 100%\nW 100%")
        label.resetCounts()

        for _ in 0..<100 {
            XCTAssertEqual(label.updateText("5h 100%\nW 100%"), width)
        }

        XCTAssertEqual(label.textAssignments, 0)
        XCTAssertEqual(label.frameAssignments, 0)
    }

    func testWidthIsMeasuredBeforeAttachmentAndDoesNotDependOnParentWidth() {
        let label = MenuBarUsageLabel()
        let narrow = label.updateText("5h 0%\nW 9%")
        let wide = label.updateText("5h 100%\nW 100%")
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertGreaterThan(narrow, 0)

        let parent = NSView(frame: .zero)
        parent.addSubview(label)
        XCTAssertEqual(label.updateText("5h 100%\nW 100%"), wide)
        parent.setFrameSize(NSSize(width: wide, height: 22))
        XCTAssertTrue(parent.bounds.contains(label.frame))
        parent.setFrameSize(NSSize(width: wide + 50, height: 37))
        XCTAssertEqual(label.preferredWidth, wide)
        XCTAssertEqual(label.frame.width, parent.bounds.width)
        XCTAssertEqual(label.frame.midY, parent.bounds.midY, accuracy: 0.5)
    }

    func testHeightChangesReflowAndRestoreLeadingWithoutChangingTextOrWidth() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 37))
        let label = MenuBarUsageLabel()
        parent.addSubview(label)
        let width = label.updateText("5h 100%\nW 100%")
        let originalHeight = label.frame.height

        parent.setFrameSize(NSSize(width: 60, height: 22))
        XCTAssertLessThanOrEqual(label.frame.height, 22)
        XCTAssertTrue(parent.bounds.contains(label.frame))
        XCTAssertEqual(label.preferredWidth, width)

        parent.setFrameSize(NSSize(width: 60, height: 37))
        XCTAssertEqual(label.frame.height, originalHeight)
        XCTAssertEqual(label.stringValue, "5h 100%\nW 100%")
        XCTAssertEqual(label.frame.midY, parent.bounds.midY, accuracy: 0.5)
    }

    func testBackingChangeWithoutGeometryChangeDoesNotInvalidateText() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        let label = RecordingUsageLabel()
        parent.addSubview(label)
        label.updateText("5h 33%\nW 48%")
        label.resetCounts()

        label.viewDidChangeBackingProperties()
        label.viewDidChangeBackingProperties()

        XCTAssertEqual(label.textAssignments, 0)
        XCTAssertEqual(label.frameAssignments, 0)
        XCTAssertNil(label.hitTest(NSPoint(x: 5, y: 5)))
        XCTAssertFalse(label.isAccessibilityElement())
    }

    func testMetadataChangesDoNotReconfigureUnchangedUsage() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let label = RecordingUsageLabel()
        let presentation = MenuBarStatusPresentation(statusItem: item, icon: NSImage(), usageLabel: label)
        defer { presentation.invalidate() }
        presentation.showUsage(title: "5h 33%\nW 48%", toolTip: "First: 10:00", accessibilityValue: "First: 33%, 48%")
        let length = item.length
        label.resetCounts()

        presentation.showUsage(title: "5h 33%\nW 48%", toolTip: "Second: 10:03", accessibilityValue: "Second: 33%, 48%")

        XCTAssertEqual(button.toolTip, "Second: 10:03")
        XCTAssertEqual(button.accessibilityValue() as? String, "Second: 33%, 48%")
        XCTAssertEqual(label.textAssignments, 0)
        XCTAssertEqual(label.frameAssignments, 0)
        XCTAssertEqual(item.length, length)
    }

    func testIconAndUsageTransitionsPreserveButtonActionAndClearStaleAccessibilityValue() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let target = ButtonActionRecorder()
        button.target = target
        button.action = #selector(ButtonActionRecorder.clicked)
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        let presentation = MenuBarStatusPresentation(statusItem: item, icon: icon)
        defer { presentation.invalidate() }
        let nativeImagePosition = button.imagePosition

        for _ in 0..<3 {
            presentation.showUsage(title: "5h 100%\nW 100%", toolTip: "Usage", accessibilityValue: "100%, 100%")
            XCTAssertNil(button.image)
            // Content changes leave the native button's layout mode intact.
            XCTAssertEqual(button.imagePosition, nativeImagePosition)
            XCTAssertFalse(presentation.usageLabel.isHidden)
            XCTAssertGreaterThanOrEqual(item.length, presentation.usageLabel.preferredWidth)
            button.performClick(nil)

            presentation.showIcon(toolTip: "Icon")
            XCTAssertTrue(button.image === icon)
            XCTAssertEqual(button.imagePosition, nativeImagePosition)
            XCTAssertTrue(presentation.usageLabel.isHidden)
            XCTAssertEqual(item.length, NSStatusItem.variableLength)
            XCTAssertNil(button.accessibilityValue())
        }
        XCTAssertEqual(target.clicks, 3)
    }

    func testRemovalDetachesLabelAndMakesFurtherUpdatesHarmless() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let presentation = MenuBarStatusPresentation(statusItem: item, icon: NSImage())
        presentation.showUsage(title: "—", toolTip: "Unavailable", accessibilityValue: "Unavailable")
        let length = item.length

        presentation.invalidate()
        presentation.showUsage(title: "5h 100%\nW 100%", toolTip: "Stale", accessibilityValue: "Stale")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertNil(presentation.usageLabel.superview)
        XCTAssertEqual(item.length, length)
        XCTAssertEqual(item.button?.toolTip, "Unavailable")
    }
}

@MainActor
private final class RecordingUsageLabel: MenuBarUsageLabel {
    var textAssignments = 0
    var frameAssignments = 0

    override var attributedStringValue: NSAttributedString {
        didSet { textAssignments += 1 }
    }

    override var frame: NSRect {
        didSet { frameAssignments += 1 }
    }

    func resetCounts() {
        textAssignments = 0
        frameAssignments = 0
    }
}

@MainActor
private final class ButtonActionRecorder: NSObject {
    var clicks = 0

    @objc func clicked() { clicks += 1 }
}
