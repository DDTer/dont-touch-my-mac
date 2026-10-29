import AppKit
let target = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.79, green: 0.98, blue: 0.29, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210).fill()
if let symbol = NSImage(systemSymbolName: "hand.raised.slash.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 480, weight: .black)) {
    let rect = NSRect(x: 242, y: 310, width: 540, height: 540)
    symbol.draw(in: rect)
    NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
    rect.fill(using: .sourceAtop)
}
let text = "HANDS OFF." as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 96, weight: .black), .foregroundColor: NSColor(calibratedWhite: 0.05, alpha: 1)]
let size = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 170), withAttributes: attrs)
image.unlockFocus()
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var body = Data()
for (size, tag) in [(128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    body.append(Data(tag.utf8)); body.append(bigEndian(png.count + 8)); body.append(png)
}
var file = Data("icns".utf8)
file.append(bigEndian(body.count + 8)); file.append(body)
try file.write(to: URL(fileURLWithPath: target))
