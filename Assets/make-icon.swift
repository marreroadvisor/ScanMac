import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let shape = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 140, yRadius: 140)
    NSColor(calibratedRed: 0.02, green: 0.11, blue: 0.15, alpha: 1).setFill()
    shape.fill()
    context.saveGState(); shape.addClip()
    NSColor(calibratedRed: 0, green: 0.70, blue: 0.58, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 174), xRadius: 104, yRadius: 104).fill()
    context.restoreGState()
    let text = NSAttributedString(string: "SM", attributes: [.font: NSFont.systemFont(ofSize: 438, weight: .heavy), .foregroundColor: NSColor.white])
    let measured = text.size()
    text.draw(at: NSPoint(x: (1024 - measured.width) / 2, y: (1024 - measured.height) / 2 + 25))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: directory.appendingPathComponent(name)) }
}
