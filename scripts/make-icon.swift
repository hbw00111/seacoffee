import AppKit

let output = CommandLine.arguments[1]
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SeaCoffee-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func draw(size: Int) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    let background = NSBezierPath(roundedRect: rect, xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(red: 0.12, green: 0.20, blue: 0.23, alpha: 1), ending: NSColor(red: 0.025, green: 0.05, blue: 0.065, alpha: 1))!.draw(in: background, angle: -60)
    let island = NSBezierPath(roundedRect: NSRect(x: 175, y: 385, width: 674, height: 270), xRadius: 135, yRadius: 135)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -20); shadow.shadowColor = .black.withAlphaComponent(0.45); shadow.set()
    NSColor.black.setFill(); island.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke(); island.lineWidth = 2; island.stroke()
    let mint = NSColor(red: 0.52, green: 0.94, blue: 0.79, alpha: 1)
    let ring = NSBezierPath(ovalIn: NSRect(x: 641, y: 455, width: 126, height: 126))
    NSColor.white.withAlphaComponent(0.13).setStroke(); ring.lineWidth = 13; ring.stroke()
    let arc = NSBezierPath(); arc.appendArc(withCenter: NSPoint(x: 704, y: 518), radius: 63, startAngle: 90, endAngle: -172, clockwise: true)
    arc.lineWidth = 13; arc.lineCapStyle = .round; mint.setStroke(); arc.stroke()
    let star = NSBezierPath(); star.move(to: NSPoint(x: 315, y: 590))
    star.curve(to: NSPoint(x: 386, y: 519), controlPoint1: NSPoint(x: 327, y: 537), controlPoint2: NSPoint(x: 333, y: 531))
    star.curve(to: NSPoint(x: 315, y: 448), controlPoint1: NSPoint(x: 333, y: 507), controlPoint2: NSPoint(x: 327, y: 501))
    star.curve(to: NSPoint(x: 244, y: 519), controlPoint1: NSPoint(x: 303, y: 501), controlPoint2: NSPoint(x: 297, y: 507))
    star.curve(to: NSPoint(x: 315, y: 590), controlPoint1: NSPoint(x: 297, y: 531), controlPoint2: NSPoint(x: 303, y: 537))
    mint.setFill(); star.fill()
    for i in 0..<3 {
        let h = CGFloat([22, 38, 28][i])
        NSBezierPath(roundedRect: NSRect(x: CGFloat(439 + i * 21), y: 519 - h / 2, width: 7, height: h), xRadius: 3.5, yRadius: 3.5).fill()
    }
    image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size: size).write(to: temporary.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2).write(to: temporary.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", output]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
