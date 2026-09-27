import AppKit
import CoreImage

// Draws the "liquid drop, ivory" icon from docs/icon.svg. AppKit's SVG renderer ignores the
// SVG's goo filter, so the merge is rebuilt here the same way: blur the drops, then cut the
// alpha at a threshold (alpha × 32 − 14), and fill that shape with the drop gradient.

let output = CommandLine.arguments[1]
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SeaCoffee-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space])
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func bitmap(_ size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in the SVG's 1024-unit, top-left coordinate system.
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
    return context
}
func blurred(_ image: CGImage, _ radius: CGFloat, size: Int) -> CIImage {
    CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: radius * CGFloat(size) / 1024)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}
func render(_ image: CIImage, size: Int) -> CGImage {
    ci.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8, colorSpace: space)!
}

let drops: [(CGFloat, CGFloat, CGFloat)] = [(505, 548, 172), (688, 392, 70), (318, 742, 50)]
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

/// The merged drop silhouette as an alpha mask, in pixel space.
func dropMask(size: Int) -> CGImage {
    let context = bitmap(size)
    context.setFillColor(rgb(0xFFFFFF))
    for (x, y, r) in drops { context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
    let threshold = CIFilter(name: "CIColorMatrix", parameters: [
        kCIInputImageKey: blurred(context.makeImage()!, 26, size: size),
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 32),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -14)])!.outputImage!
    let rgba = render(threshold.applyingFilter("CIColorClamp"), size: size)
    // Flattened onto black, the white silhouette becomes the grayscale mask clip(to:mask:) expects.
    let gray = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    gray.draw(rgba, in: CGRect(x: 0, y: 0, width: size, height: size))
    return gray.makeImage()!
}

/// A soft blurred shape drawn as its own layer (glows and contact shadows).
func softLayer(size: Int, blur: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let context = bitmap(size)
    draw(context)
    return render(blurred(context.makeImage()!, blur, size: size), size: size)
}

func draw(size: Int) -> Data {
    let pixel = CGRect(x: 0, y: 0, width: size, height: size)
    let context = bitmap(size)
    let mask = dropMask(size: size)

    // Squircle body: soft outer shadow, ivory gradient, top sheen, hairline rim.
    context.saveGState()
    // Shadow offset and blur are in pixels, not the scaled SVG units.
    let unit = CGFloat(size) / 1024
    context.setShadow(offset: CGSize(width: 0, height: -16 * unit), blur: 40 * unit, color: rgb(0x000000, 0.18))
    context.addPath(bodyPath); context.setFillColor(rgb(0xF6F1E8)); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(bodyPath); context.clip()
    let ivory = CGGradient(colorsSpace: space, colors: [rgb(0xFFFDF7), rgb(0xEDE5D6)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(ivory, start: CGPoint(x: 100 + 824 * 0.2, y: 100), end: CGPoint(x: 100 + 824 * 0.8, y: 924),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 0.4])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    context.restoreGState()
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    context.setStrokeColor(rgb(0x000000, 0.06)); context.setLineWidth(3); context.strokePath()

    // Layers already in pixel space are drawn without the SVG transform.
    func drawPixels(_ image: CGImage) {
        context.saveGState(); context.concatenate(context.ctm.inverted()); context.draw(image, in: pixel); context.restoreGState()
    }
    drawPixels(softLayer(size: size, blur: 60) { c in
        c.setFillColor(rgb(0xFF8A1F, 0.20)); c.fillEllipse(in: CGRect(x: 512 - 230, y: 540 - 230, width: 460, height: 460))
    })
    drawPixels(softLayer(size: size, blur: 22) { c in
        c.setFillColor(rgb(0xB4661E, 0.28)); c.fillEllipse(in: CGRect(x: 505 - 170, y: 760 - 26, width: 340, height: 52))
    })
    // The drop's own shadow is its silhouette, blurred and pushed down.
    let shadowTint = softLayer(size: size, blur: 18) { c in
        c.saveGState(); c.concatenate(c.ctm.inverted())
        c.clip(to: pixel.offsetBy(dx: 0, dy: -18 * CGFloat(size) / 1024), mask: mask)
        c.setFillColor(rgb(0xB4661E, 0.30)); c.fill(pixel); c.restoreGState()
    }
    drawPixels(shadowTint)

    // The merged drop. As in the SVG, each drop carries its own highlight gradient (the gradient
    // is sized to each circle), the colours are blurred together, and the silhouette cuts them.
    let drop = CGGradient(colorsSpace: space, colors: [rgb(0xFFD08A), rgb(0xFF9A2E), rgb(0xE5600E)] as CFArray, locations: [0, 0.45, 1])!
    let colours = bitmap(size)
    for (x, y, r) in drops {
        colours.saveGState()
        colours.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)); colours.clip()
        let centre = CGPoint(x: x - r + 2 * r * 0.38, y: y - r + 2 * r * 0.32)
        colours.drawRadialGradient(drop, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 2 * r * 0.8,
                                   options: [.drawsAfterEndLocation])
        colours.restoreGState()
    }
    // CIColorMatrix works on unpremultiplied colour, so forcing alpha to 1 keeps the true hue at the edges.
    let merged = blurred(colours.makeImage()!, 26, size: size)
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    context.saveGState()
    context.concatenate(context.ctm.inverted()); context.clip(to: pixel, mask: mask)
    context.draw(render(merged, size: size), in: pixel)
    context.restoreGState()

    // Specular highlights.
    context.saveGState()
    context.translateBy(x: 440, y: 466); context.rotate(by: -32 * .pi / 180)
    context.setFillColor(rgb(0xFFFFFF, 0.5)); context.fillEllipse(in: CGRect(x: -66, y: -36, width: 132, height: 72))
    context.restoreGState()
    context.setFillColor(rgb(0xFFFFFF, 0.45)); context.fillEllipse(in: CGRect(x: 704 - 16, y: 372 - 16, width: 32, height: 32))

    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 2 {
    // `make-icon.swift out.icns preview.png` also writes a 1024 px preview.
    try draw(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
for size in [16, 32, 128, 256, 512] {
    try draw(size: size).write(to: temporary.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2).write(to: temporary.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", output]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
