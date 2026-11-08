// render <page.html> <out.png> <width> <height>
// Renders a standalone HTML page to a PNG at 2x in an offscreen WebKit view.
// Board files are first made standalone by prep.py.
import AppKit
import WebKit

_ = NSApplication.shared
let args = CommandLine.arguments
let html = try! String(contentsOfFile: args[1], encoding: .utf8)
let out = args[2]
let w = Double(args[3])!, h = Double(args[4])!

final class Delegate: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

// Far off screen and never key: nothing shows on the user's display.
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
web.setValue(false, forKey: "drawsBackground")
window.contentView = web
window.orderFront(nil)
let d = Delegate()
web.navigationDelegate = d
web.loadHTMLString(html, baseURL: nil)
while !d.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
let config = WKSnapshotConfiguration()
config.rect = NSRect(x: 0, y: 0, width: w, height: h)
config.snapshotWidth = NSNumber(value: w)
var finished = false
web.takeSnapshot(with: config) { image, error in
    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("failed", error as Any); exit(1) }
    try! png.write(to: URL(fileURLWithPath: out))
    finished = true
}
while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
