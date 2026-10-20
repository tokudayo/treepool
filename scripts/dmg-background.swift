import AppKit

// Finder uses points for the window and icon positions; keep this canvas in sync.
let size = NSSize(width: 660, height: 400)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
func label(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (text as NSString).size(withAttributes: attributes).width
    (text as NSString).draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attributes)
}
label("Install Treepool", y: 330, font: .systemFont(ofSize: 26, weight: .semibold), color: .black)
label("Drag Treepool into Applications", y: 60, font: .systemFont(ofSize: 17), color: .darkGray)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 290, y: 210))
arrow.line(to: NSPoint(x: 370, y: 210))
arrow.move(to: NSPoint(x: 354, y: 226))
arrow.line(to: NSPoint(x: 370, y: 210))
arrow.line(to: NSPoint(x: 354, y: 194))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
arrow.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
