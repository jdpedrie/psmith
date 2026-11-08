// montage <out.png> <cols> <cellWidth> <files...>
// Tiles images, scaled to cellWidth, with each file's name under it.
import AppKit

let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cw = CGFloat(Double(a[3])!)
let files = Array(a[4...])
let imgs = files.map { NSImage(contentsOfFile: $0)! }
let ch = imgs.map { $0.size.height * cw / $0.size.width }.max()! + 22
let rows = (imgs.count + cols - 1) / cols
let size = NSSize(width: CGFloat(cols) * (cw + 10), height: CGFloat(rows) * (ch + 10))
let canvas = NSImage(size: size)
canvas.lockFocus()
NSColor(white: 0.5, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
for (i, img) in imgs.enumerated() {
    let c = i % cols, r = i / cols
    let h = img.size.height * cw / img.size.width
    let x = CGFloat(c) * (cw + 10), top = size.height - CGFloat(r) * (ch + 10)
    img.draw(in: NSRect(x: x, y: top - h, width: cw, height: h))
    let name = (files[i] as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
    (name as NSString).draw(at: NSPoint(x: x + 4, y: top - h - 18), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
