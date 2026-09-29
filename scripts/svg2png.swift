import AppKit
import WebKit

// Renders an SVG to a PNG with WebKit (full SVG filter support) on a transparent background.
//   svg2png IN.svg OUT.png SIZE      (used by scripts/make-icon.sh)
let args = CommandLine.arguments
let size = CGFloat(Double(args[3]) ?? 1024)
let svg = try! String(contentsOfFile: args[1], encoding: .utf8)
let app = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
web.setValue(false, forKey: "drawsBackground")
let html = "<html><body style='margin:0;background:transparent'><div style='width:\(Int(size))px;height:\(Int(size))px'>"
    + svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"\(Int(size))\" height=\"\(Int(size))\"")
    + "</div></body></html>"
final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: size, height: size)
            config.snapshotWidth = NSNumber(value: Double(size) / Double(NSScreen.main?.backingScaleFactor ?? 2))
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    print("failed", error as Any); exit(1)
                }
                // Resample to exactly SIZE×SIZE pixels.
                let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
        }
    }
}
let delegate = Delegate()
web.navigationDelegate = delegate
web.loadHTMLString(html, baseURL: nil)
app.run()
