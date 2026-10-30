import AppKit

/// A drawing-only label inside NSStatusBarButton. NSTextField's own layout and
/// Auto Layout can invalidate AppKit's status-item snapshot continuously, even
/// when the text is unchanged. Drawing here never changes layout or content.
@MainActor
class MenuBarUsageLabel: NSView {
    private let usageFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private var usageText = ""
    private var renderedLineHeight: CGFloat?
    private var measuredSize: NSSize = .zero
    private let measuringCell = NSTextFieldCell(textCell: "")
    var attributedStringValue = NSAttributedString(string: "") {
        didSet { needsDisplay = true }
    }
    var stringValue: String { attributedStringValue.string }
    private lazy var naturalLineHeight: CGFloat = {
        let measuringCell = NSTextFieldCell(textCell: "5h 100%")
        measuringCell.font = usageFont
        return measuringCell.cellSize.height
    }()

    var preferredWidth: CGFloat { ceil(measuredSize.width) }

    init() {
        super.init(frame: .zero)
        measuringCell.font = usageFont
        measuringCell.isBordered = false
        measuringCell.lineBreakMode = .byClipping
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .minYMargin, .maxYMargin]
        // The status button exposes the current usage as its accessibility
        // value and handles all pointer/keyboard actions.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func updateText(_ text: String) -> CGFloat {
        if text != usageText {
            usageText = text
            renderedLineHeight = nil
        }
        updatePlacement()
        return preferredWidth
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Match the text cell's two-point horizontal inset. Its measured size
        // already includes this inset, so text fits without an extra margin.
        attributedStringValue.draw(
            with: bounds.insetBy(dx: 2, dy: 0),
            options: [.usesLineFragmentOrigin]
        )
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updatePlacement()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePlacement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePlacement()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePlacement()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updatePlacement() {
        guard !usageText.isEmpty else { return }
        let lineCount: CGFloat = usageText.contains("\n") ? 2 : 1
        let availableHeight = superview?.bounds.height ?? 0
        // Measure normally before attachment / while AppKit has zero bounds.
        // On shorter menu bars, tighten leading without shrinking the font.
        let lineHeight = availableHeight >= lineCount
            ? min(naturalLineHeight, floor(availableHeight / lineCount))
            : naturalLineHeight
        if renderedLineHeight != lineHeight {
            renderedLineHeight = lineHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byClipping
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            attributedStringValue = NSAttributedString(string: usageText, attributes: [
                .font: usageFont,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.labelColor
            ])
            // cellSize measures text directly; fittingSize would involve the
            // enclosing view's Auto Layout engine. Leading never changes width.
            measuringCell.attributedStringValue = attributedStringValue
            measuredSize = measuringCell.cellSize
        }

        guard let parent = superview, parent.bounds.width > 0, availableHeight > 0 else { return }
        let proposed = NSRect(
            x: parent.bounds.minX,
            y: parent.bounds.midY - measuredSize.height / 2,
            width: parent.bounds.width,
            height: measuredSize.height
        )
        let aligned = parent.backingAlignedRect(proposed, options: [
            .alignMinXNearest, .alignMaxXNearest, .alignMinYNearest, .alignMaxYNearest
        ])
        if frame != aligned {
            frame = aligned
        }
        // Never resize the parent or NSStatusItem from this path. AppKit can
        // call it while taking a menu-bar snapshot; keep sizing one-directional.
    }
}
