import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("需要 PNG 输出路径") }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.075, blue: 0.13, alpha: 1),
           ending: NSColor(srgbRed: 0.11, green: 0.22, blue: 0.32, alpha: 1))!.draw(in: tile, angle: 90)
let rim = NSBezierPath(roundedRect: NSRect(x: 78, y: 78, width: 868, height: 868), xRadius: 184, yRadius: 184)
rim.lineWidth = 2
NSColor.white.withAlphaComponent(0.09).setStroke()
rim.stroke()

func port(_ points: [NSPoint], color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = 72
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 20
shadow.shadowOffset = NSSize(width: 0, height: -9)
shadow.set()
let ice = NSColor(srgbRed: 0.79, green: 0.96, blue: 1, alpha: 1)
let cyan = NSColor(srgbRed: 0.20, green: 0.79, blue: 0.91, alpha: 1)
port([NSPoint(x: 414, y: 744), NSPoint(x: 296, y: 744), NSPoint(x: 296, y: 280), NSPoint(x: 414, y: 280)], color: ice)
port([NSPoint(x: 610, y: 744), NSPoint(x: 728, y: 744), NSPoint(x: 728, y: 280), NSPoint(x: 610, y: 280)], color: ice)
port([NSPoint(x: 304, y: 512), NSPoint(x: 720, y: 512)], color: cyan)
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("图标生成失败") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
