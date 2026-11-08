// score <board.png> <real.png>
// Prints the percent of pixels whose largest channel difference exceeds 48.
// Antialiasing alone stays under about 5.
import AppKit

func pixels(_ path: String) -> (w: Int, h: Int, data: [UInt8]) {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, data)
}

let a = pixels(CommandLine.arguments[1]), b = pixels(CommandLine.arguments[2])
let w = min(a.w, b.w), h = min(a.h, b.h)
var bad = 0
for y in 0..<h {
    for x in 0..<w {
        let ia = (y * a.w + x) * 4, ib = (y * b.w + x) * 4
        var m = 0
        for c in 0..<3 { m = max(m, abs(Int(a.data[ia + c]) - Int(b.data[ib + c]))) }
        if m > 48 { bad += 1 }
    }
}
print(String(format: "%.1f", Double(bad) * 100 / Double(w * h)))
