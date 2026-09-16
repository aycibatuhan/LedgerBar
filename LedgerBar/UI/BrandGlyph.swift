import AppKit

/// The LedgerBar "LB monogram" drawn in code: an L and a B built from
/// ledger-like strokes. The geometry is the 1024-point grid of
/// `Design/AppIcon.svg`; `Tools/render-app-icon.swift` renders the same
/// paths for the app icon. Drawing the menu-bar glyph at runtime keeps the
/// SwiftPM build (no asset catalog) visually identical to the Xcode bundle.
enum BrandGlyph {
    private static let stroke: CGFloat = 104
    /// Bounding box of the ink on the 1024 grid.
    private static let inkBounds = CGRect(x: 300, y: 296, width: 424, height: 432)

    /// 18 pt template image for `MenuBarExtra`; resolution independent because
    /// AppKit invokes the drawing handler per backing scale.
    @MainActor static let menuBarImage: NSImage = {
        let points: CGFloat = 18
        let inset: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let fit = (points - inset * 2) / max(inkBounds.width, inkBounds.height)
            let drawn = CGSize(width: inkBounds.width * fit, height: inkBounds.height * fit)
            ctx.translateBy(x: (points - drawn.width) / 2, y: (points - drawn.height) / 2)
            ctx.scaleBy(x: fit, y: fit)
            ctx.translateBy(x: -inkBounds.minX, y: -inkBounds.minY)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            bTop().fill()
            bBowl().stroke()
            ledgerL().stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LedgerBar"
        return image
    }()

    /// The "L": a stem whose foot doubles as the bottom of the "B".
    private static func ledgerL() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 352, y: 296))
        p.line(to: CGPoint(x: 352, y: 676))
        p.line(to: CGPoint(x: 584, y: 676))
        p.lineWidth = stroke
        p.lineCapStyle = .butt
        p.lineJoinStyle = .round
        return p
    }

    /// The top bar of the "B".
    private static func bTop() -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: 456, y: 296, width: 196, height: stroke), xRadius: 22, yRadius: 22)
    }

    /// The lower bowl of the "B", ending under the foot of the "L".
    private static func bBowl() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 456, y: 508))
        p.line(to: CGPoint(x: 588, y: 508))
        p.curve(to: CGPoint(x: 672, y: 592),
                controlPoint1: CGPoint(x: 634, y: 508),
                controlPoint2: CGPoint(x: 672, y: 546))
        p.curve(to: CGPoint(x: 588, y: 676),
                controlPoint1: CGPoint(x: 672, y: 638),
                controlPoint2: CGPoint(x: 634, y: 676))
        p.line(to: CGPoint(x: 560, y: 676))
        p.lineWidth = stroke
        p.lineCapStyle = .butt
        p.lineJoinStyle = .round
        return p
    }
}
