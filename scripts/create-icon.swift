import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("需要 PNG 输出路径") }
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let png = try Data(contentsOf: root.appendingPathComponent("packaging/Icon/HostDock.png"))
guard let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide == 1024,
      bitmap.pixelsHigh == 1024, bitmap.hasAlpha else { fatalError("图标母版必须是 1024 × 1024 透明 PNG") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
