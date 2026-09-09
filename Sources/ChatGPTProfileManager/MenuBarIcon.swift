import AppKit

/// A compact monochrome version of the app's P mark for the menu bar.
enum MenuBarIcon {
    static func make(bundle: Bundle = .main) -> NSImage {
        if let resourceURL = bundle.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
           let resourceImage = NSImage(contentsOf: resourceURL) {
            resourceImage.isTemplate = true
            resourceImage.size = NSSize(width: 18, height: 18)
            return resourceImage
        }

        return makeFallback()
    }

    private static func makeFallback() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = true
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        let stem = NSBezierPath(
            roundedRect: NSRect(x: 4.7, y: 3.0, width: 5.3, height: 12.0),
            xRadius: 2.65,
            yRadius: 2.65
        )
        stem.fill()

        let bowl = NSBezierPath(
            roundedRect: NSRect(x: 7.6, y: 8.6, width: 6.7, height: 6.0),
            xRadius: 3.0,
            yRadius: 3.0
        )
        let bowlOpening = NSBezierPath(ovalIn: NSRect(x: 9.0, y: 10.1, width: 3.0, height: 2.1))
        bowl.append(bowlOpening)
        bowl.windingRule = .evenOdd
        bowl.fill()

        return image
    }
}
