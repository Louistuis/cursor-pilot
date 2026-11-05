// Draws Cursor Pilot's app icon: a dark glass tile lit from its edges by the
// app's own glow shader, with a frosted-glass pilot arrow in the middle.
// Built and run by scripts/make-icon.sh together with Glow.swift.
import AppKit
import CoreImage

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// Clips to the outline of `path` stroked at `width`, inside `path` only.
func clipToInnerStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat) {
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(path)
    ctx.setLineWidth(width * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
}

let ciContext = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])

/// `path` stroked `width` wide with `fill`, blurred: soft light along an edge.
func blurredStroke(_ path: CGPath, width: CGFloat, sigma: CGFloat, fill: CGGradient, from a: CGPoint, to b: CGPoint) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(fill, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let ci = CIImage(cgImage: ctx.makeImage()!).applyingGaussianBlur(sigma: sigma)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space)!
}

func renderMaster() -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // macOS icon grid: an 824pt rounded tile centred on the canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 185
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.42))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.04, 0.04, 0.08))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark glass body.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(color(0.12, 0.13, 0.22), 0), (color(0.05, 0.05, 0.10), 0.6), (color(0.03, 0.03, 0.06), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The rainbow frame: the same light the app paints around the screen,
    // fading in from the edges.
    let glow = GlowState(rect: tile, radii: (corner, corner, corner, corner), gain: 1.05, fill: 0, outer: 0, rot: 0.62)
    if let light = GlowView.image(of: glow, size: CGSize(width: size, height: size), scale: 1) {
        ctx.draw(light, in: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // Glass sheen across the top and a lit hairline edge.
    ctx.drawLinearGradient(gradient([(color(1, 1, 1, 0.11), 0), (color(1, 1, 1, 0), 0.42)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    clipToInnerStroke(ctx, tilePath, width: 2.5)
    ctx.drawLinearGradient(gradient([(color(1, 1, 1, 0.45), 0), (color(1, 1, 1, 0.06), 0.55), (color(1, 1, 1, 0.14), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The pilot arrow: ArrowShape's corners (Overlay.swift), y down.
    // Placed so the arrow's visible outline (not its rect, which the rounded
    // wing and tail don't reach) sits in the middle of the tile.
    let r = CGRect(x: 325, y: 207, width: 472, height: 547)
    let corners: [(CGFloat, CGFloat, CGFloat)] = [(0.02, 0.01, 0.09), (1.00, 0.58, 0.15), (0.45, 0.66, 0.05), (0.13, 1.00, 0.15)]
    func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.maxY - r.height * fy) }
    let pts = corners.map { p($0.0, $0.1) }
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: (pts[0].x + pts[3].x) / 2, y: (pts[0].y + pts[3].y) / 2))
    for i in pts.indices {
        arrow.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count], radius: corners[i].2 * min(r.width, r.height))
    }
    arrow.closeSubpath()

    // What the glass sees: the tile behind it, blurred and a little brighter.
    let behind = ctx.makeImage()!
    let ci = CIImage(cgImage: behind).clampedToExtent()
        .applyingGaussianBlur(sigma: 34)
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5])
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    let frosted = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space)!

    // Light under the glass, then its shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 90, color: color(0.45, 0.42, 1, 0.75))
    ctx.addPath(arrow)
    ctx.setFillColor(color(0.2, 0.2, 0.35))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0, 0, 0, 0.5))
    ctx.addPath(arrow)
    ctx.setFillColor(color(0.2, 0.2, 0.35))
    ctx.fillPath()
    ctx.restoreGState()

    // Frosted body with a milky tint, brighter toward the tip.
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    ctx.draw(frosted, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.drawLinearGradient(gradient([(color(1, 1, 1, 0.22), 0), (color(0.92, 0.94, 1, 0.07), 0.6), (color(0.85, 0.88, 1, 0.02), 1)]),
                           start: p(0.05, 0.05), end: p(0.75, 0.95), options: [])
    // Specular bloom near the tip.
    ctx.drawRadialGradient(gradient([(color(1, 1, 1, 0.32), 0), (color(1, 1, 1, 0), 1)]),
                           startCenter: p(0.22, 0.2), startRadius: 0, endCenter: p(0.22, 0.2), endRadius: 160, options: [])
    ctx.restoreGState()

    // Light caught inside the glass: colour pooling along the edges and
    // fading toward the middle.
    let rainbow = gradient([(color(0.35, 0.9, 1, 1), 0), (color(0.5, 0.5, 1, 1), 0.35), (color(1, 0.4, 0.85, 1), 0.68),
                            (color(1, 0.72, 0.35, 1), 1)])
    let innerGlow = blurredStroke(arrow, width: 46, sigma: 22, fill: rainbow, from: p(0, 0.1), to: p(0.9, 1))
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    ctx.setBlendMode(.screen)
    ctx.draw(innerGlow, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.draw(innerGlow, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()

    // Refraction: the rainbow bending through the glass edge.
    ctx.saveGState()
    clipToInnerStroke(ctx, arrow, width: 5)
    ctx.setBlendMode(.screen)
    ctx.drawLinearGradient(gradient([(color(0.35, 0.9, 1, 0.9), 0), (color(0.55, 0.45, 1, 0.9), 0.35), (color(1, 0.4, 0.85, 0.9), 0.65),
                                     (color(1, 0.7, 0.35, 0.9), 1)]),
                           start: p(0, 0.1), end: p(0.9, 1), options: [])
    ctx.restoreGState()

    // Lit glass edge: bright where the light hits (tip, top), faint below.
    ctx.saveGState()
    clipToInnerStroke(ctx, arrow, width: 3.5)
    ctx.drawLinearGradient(gradient([(color(1, 1, 1, 1), 0), (color(1, 1, 1, 0.4), 0.45), (color(1, 1, 1, 0.1), 1)]),
                           start: p(0, 0), end: p(0.8, 1), options: [])
    ctx.restoreGState()

    // A glint on the tip.
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    ctx.translateBy(x: p(0.1, 0.1).x, y: p(0.1, 0.1).y)
    ctx.rotate(by: -0.6)
    ctx.scaleBy(x: 1, y: 0.35)
    ctx.drawRadialGradient(gradient([(color(1, 1, 1, 0.85), 0), (color(1, 1, 1, 0), 1)]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 60, options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let master = renderMaster()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("CursorPilot-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: set) }
for px in [16, 32, 128, 256, 512] {
    try scaled(master, to: px).write(to: set.appendingPathComponent("icon_\(px)x\(px).png"))
    try scaled(master, to: px * 2).write(to: set.appendingPathComponent("icon_\(px)x\(px)@2x.png"))
}
if let preview = ProcessInfo.processInfo.environment["CP_ICON_PREVIEW"] {
    try scaled(master, to: size).write(to: URL(fileURLWithPath: preview))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
