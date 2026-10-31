import AppKit
import Foundation

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)] {
    let scale = CGFloat(size) / 1024
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.18, alpha: 1).setFill(); background.fill()
    let machine = NSBezierPath(roundedRect: NSRect(x: 228, y: 320, width: 568, height: 400), xRadius: 83, yRadius: 83)
    NSColor(calibratedRed: 0.82, green: 0.89, blue: 0.84, alpha: 1).setFill(); machine.fill()
    NSColor(calibratedRed: 0.63, green: 0.73, blue: 0.66, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 260, y: 352, width: 504, height: 24), xRadius: 12, yRadius: 12).fill()
    NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.26, alpha: 1).setStroke()
    let check = NSBezierPath(); check.lineWidth = 53; check.lineCapStyle = .round; check.lineJoinStyle = .round
    check.move(to: CGPoint(x: 396, y: 529)); check.line(to: CGPoint(x: 482, y: 449)); check.line(to: CGPoint(x: 644, y: 613)); check.stroke()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 728, y: 393, width: 15, height: 15)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
