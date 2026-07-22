// Renders the eclipse-chrome icon offscreen via WKWebView (same engine the
// overlay uses), then writes a 1024px PNG. Run:
//   swiftc -O RenderIcon.swift -o render-icon && ./render-icon <html> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: render-icon <html> <out.png>\n", stderr); exit(2) }
let htmlPath = args[1], outPath = args[2]

let html: String
do { html = try String(contentsOfFile: htmlPath, encoding: .utf8) }
catch { fputs("cannot read \(htmlPath): \(error)\n", stderr); exit(2) }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let cfg = WKWebViewConfiguration()
let size = CGSize(width: 1024, height: 1024)
let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
// Transparent backing so the PNG keeps its alpha channel.
web.setValue(false, forKey: "drawsBackground")

final class Nav: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        fputs("nav failed: \(e)\n", stderr); exit(1)
    }
}
let nav = Nav()
web.navigationDelegate = nav
web.loadHTMLString(html, baseURL: nil)

// Pump the runloop until the page reports it finished drawing.
let deadline = Date().addingTimeInterval(20)
while !nav.done && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
guard nav.done else { fputs("timed out loading page\n", stderr); exit(1) }

// Let the canvas paint + a couple of frames settle.
var drawn = false
for _ in 0..<200 {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    var ready = false, checked = false
    web.evaluateJavaScript("window.__done === true") { v, _ in
        ready = (v as? Bool) ?? false; checked = true
    }
    let t = Date().addingTimeInterval(1.0)
    while !checked && Date() < t {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if ready { drawn = true; break }
}
guard drawn else { fputs("canvas never signalled __done\n", stderr); exit(1) }

// Extra settle so the composited layer is up to date before snapshotting.
for _ in 0..<25 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }

let snapCfg = WKSnapshotConfiguration()
snapCfg.rect = CGRect(origin: .zero, size: size)
if #available(macOS 10.15, *) { snapCfg.afterScreenUpdates = true }

var finished = false, failed: String? = nil
web.takeSnapshot(with: snapCfg) { image, error in
    defer { finished = true }
    if let error = error { failed = "snapshot failed: \(error)"; return }
    guard let image = image,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { failed = "no image data"; return }
    // Force exact pixel dimensions — takeSnapshot is point-based and would
    // otherwise hand back a 2x image on a Retina display.
    rep.size = size
    guard let png = rep.representation(using: .png, properties: [:]) else {
        failed = "png encode failed"; return
    }
    do { try png.write(to: URL(fileURLWithPath: outPath)) }
    catch { failed = "write failed: \(error)" }
}

let snapDeadline = Date().addingTimeInterval(20)
while !finished && Date() < snapDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
if let failed = failed { fputs(failed + "\n", stderr); exit(1) }
guard finished else { fputs("snapshot timed out\n", stderr); exit(1) }
print("wrote \(outPath)")
