// Renders the LedgerBar "LB monogram" app icon (Design/AppIcon.svg is the
// reference drawing) into the asset catalog with CoreGraphics only, so the
// artwork is reproducible from source without third-party tooling.
//
//   swift Tools/render-app-icon.swift LedgerBar/Resources/Assets.xcassets
//
// Writes AppIcon.appiconset (macOS sizes 16…1024). File names follow the
// `iconutil` iconset convention so Tools/build-local-app.sh can assemble an
// .icns from the same PNGs. The menu-bar glyph is drawn at runtime by
// LedgerBar/UI/BrandGlyph.swift from the same geometry; keep the two in sync.
import AppKit
import Foundation

// MARK: - Geometry (1024-point grid, y grows downward)

let canvas: CGFloat = 1024
let stroke: CGFloat = 104
let backgroundTop = NSColor(srgbRed: 0.165, green: 0.216, blue: 0.298, alpha: 1)   // #2A374C
let backgroundBottom = NSColor(srgbRed: 0.098, green: 0.133, blue: 0.188, alpha: 1) // #192230
let inkWhite = NSColor(srgbRed: 0.953, green: 0.965, blue: 0.976, alpha: 1)         // #F3F6F9
let inkBlue = NSColor(srgbRed: 0.663, green: 0.753, blue: 0.855, alpha: 1)          // #A9C0DA

/// The white "L": a stem with a foot that doubles as the bottom of the "B".
func ledgerL() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: 352, y: 296))
    p.line(to: CGPoint(x: 352, y: 676))
    p.line(to: CGPoint(x: 584, y: 676))
    p.lineWidth = stroke
    p.lineCapStyle = .butt
    p.lineJoinStyle = .round
    return p
}

/// The blue top bar of the "B".
func ledgerBTop() -> NSBezierPath {
    let rect = CGRect(x: 456, y: 296, width: 196, height: stroke)
    return NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
}

/// The blue lower bowl of the "B", ending under the white foot.
func ledgerBBowl() -> NSBezierPath {
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

// MARK: - Drawing

func flipped(_ size: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.translateBy(x: 0, y: size)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.setShouldAntialias(true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawGlyph() {
    inkBlue.setFill()
    ledgerBTop().fill()
    inkBlue.setStroke()
    ledgerBBowl().stroke()
    inkWhite.setStroke()
    ledgerL().stroke()
}

/// macOS app icon: the artwork sits on the 824×824 squircle of the 1024 grid.
func appIcon(pixels: CGFloat) -> NSBitmapImageRep {
    flipped(pixels) {
        let scale = pixels / canvas
        NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)
        NSGradient(starting: backgroundTop, ending: backgroundBottom)!.draw(in: squircle, angle: 90)
        drawGlyph()
    }
}

// MARK: - Output

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: url)
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift <Assets.xcassets>\n".utf8))
    exit(2)
}
let catalog = URL(fileURLWithPath: arguments[1])
let fm = FileManager.default

let appIconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try fm.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try writeJSON(["info": ["author": "xcode", "version": 1]], to: catalog.appendingPathComponent("Contents.json"))

var appImages: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let filename = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    try writePNG(appIcon(pixels: CGFloat(points * scale)), to: appIconSet.appendingPathComponent(filename))
    appImages.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
try writeJSON(["images": appImages, "info": ["author": "xcode", "version": 1]],
              to: appIconSet.appendingPathComponent("Contents.json"))

print("wrote \(appImages.count) app icon sizes to \(catalog.path)")
