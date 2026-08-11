import AppKit
import WebKit

/// Transparent, click-through, always-on-top voice indicator that follows the
/// cursor. Renders the "Eclipse Dark Chrome" design in a WKWebView so the visual
/// can be iterated purely in HTML/canvas. Live mic level + state are pushed to
/// the page via JS.
final class Overlay {
    enum Vis { case hidden, listening, transcribing }

    // Keep the same artwork, but render it at half the original footprint so
    // it stays present without covering the text being dictated into.
    private let size: CGFloat = 100
    private let offset = CGPoint(x: 16, y: 16) // upper-right of the cursor, close
    private let window: NSWindow
    private let web: WKWebView
    private var followTimer: Timer?
    private var loaded = false
    private var pendingMode: String?
    private var theme: String = "dark"

    init() {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: rect, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground") // transparent webview
        web.autoresizingMask = [.width, .height]

        window.contentView = web
        window.orderOut(nil)

        loadHTML()
    }

    private func loadHTML() {
        guard let url = Bundle.main.url(forResource: "overlay", withExtension: "html") else {
            NSLog("[overlay] overlay.html not found in bundle")
            return
        }
        web.navigationDelegate = NavDelegate.shared
        NavDelegate.shared.onFinish = { [weak self] in
            guard let self = self else { return }
            self.loaded = true
            self.js("window.__setTheme('\(self.theme)')")
            if let m = self.pendingMode { self.js("window.__setMode('\(m)')") }
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func setLevel(_ level: Float) {
        js("window.__setVolume(\(level))")
    }

    /// Set the overlay color theme ("dark" | "light"). Persists across shows.
    func setTheme(_ name: String) {
        theme = name
        if loaded { js("window.__setTheme('\(name)')") }
    }

    func show(_ vis: Vis) {
        switch vis {
        case .hidden:
            stopFollowing()
            setMode("idle")
            window.orderOut(nil)
        case .listening:
            setMode("listening")
            moveToCursor()
            window.orderFrontRegardless()
            startFollowing()
        case .transcribing:
            setMode("transcribing")
        }
    }

    private func setMode(_ m: String) {
        pendingMode = m
        if loaded { js("window.__setMode('\(m)')") }
    }

    private func js(_ script: String) {
        guard loaded else { return }
        web.evaluateJavaScript(script, completionHandler: nil)
    }

    private func startFollowing() {
        stopFollowing()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.moveToCursor()
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func moveToCursor() {
        // Center the halo just up-and-right of the pointer. mouseLocation origin
        // is bottom-left; window origin is its bottom-left corner.
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: p.x + offset.x, y: p.y + offset.y - size / 2))
    }
}

/// Minimal navigation delegate to know when the page finished loading.
private final class NavDelegate: NSObject, WKNavigationDelegate {
    static let shared = NavDelegate()
    var onFinish: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }
}
