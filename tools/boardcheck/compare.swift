// compare <board.png> <real.png> <out-prefix>
// Writes <prefix>-side.png (board | real) and <prefix>-diff.png (brightened
// absolute difference), aligned at their top-left corners.
import AppKit

let args = CommandLine.arguments
let a = NSImage(contentsOfFile: args[1])!, b = NSImage(contentsOfFile: args[2])!
let ra = NSBitmapImageRep(data: a.tiffRepresentation!)!, rb = NSBitmapImageRep(data: b.tiffRepresentation!)!
let w = ra.pixelsWide, h = ra.pixelsHigh

func write(_ img: NSImage, _ path: String) {
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let side = NSImage(size: NSSize(width: w * 2 + 20, height: h))
side.lockFocus()
NSColor.magenta.setFill(); NSRect(x: w, y: 0, width: 20, height: h).fill()
ra.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
rb.draw(in: NSRect(x: w + 20, y: 0, width: rb.pixelsWide, height: rb.pixelsHigh))
side.unlockFocus()
write(side, args[3] + "-side.png")

let diff = NSImage(size: NSSize(width: w, height: h))
diff.lockFocus()
ra.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
rb.draw(in: NSRect(x: 0, y: 0, width: rb.pixelsWide, height: rb.pixelsHigh), from: .zero, operation: .difference, fraction: 1, respectFlipped: false, hints: nil)
diff.unlockFocus()
write(diff, args[3] + "-diff.png")
