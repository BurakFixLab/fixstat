import AppKit
import WebKit

// Renders an SVG to a PNG with WebKit (full SVG filter support) on a transparent background.
//   svg2png IN.svg OUT.png WIDTH [HEIGHT]     (used by make-icon.sh and package-release.sh)
// The SVG's root element must say width="1024" height="1024"; its viewBox sets the aspect.
let args = CommandLine.arguments
let width = CGFloat(Double(args[3]) ?? 1024)
let height = args.count > 4 ? CGFloat(Double(args[4]) ?? Double(width)) : width
let svg = try! String(contentsOfFile: args[1], encoding: .utf8)
let app = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
web.setValue(false, forKey: "drawsBackground")
let html = "<html><body style='margin:0;background:transparent'><div style='width:\(Int(width))px;height:\(Int(height))px'>"
    + svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"\(Int(width))\" height=\"\(Int(height))\"")
    + "</div></body></html>"
final class Delegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: width, height: height)
            config.snapshotWidth = NSNumber(value: Double(width) / Double(NSScreen.main?.backingScaleFactor ?? 2))
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    print("failed", error as Any); exit(1)
                }
                // Resample to exactly WIDTH×HEIGHT pixels.
                let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
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
