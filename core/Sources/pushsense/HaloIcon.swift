import AppKit

/// Draws the "halo rings" logo (concept A) as a template NSImage — solid core
/// plus two concentric fading rings. Template = auto black/white for the menubar.
enum HaloIcon {
    static func image(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            // Bolder proportions so it reads clearly at 18px in the menubar.
            let coreR = size * 0.16
            let ring1R = size * 0.34
            let ring2R = size * 0.48
            let lw = size * 0.09

            NSColor.black.setFill()

            // core
            NSBezierPath(ovalIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)).fill()

            // ring 1 (strong)
            let r1 = NSBezierPath(ovalIn: CGRect(x: c.x - ring1R, y: c.y - ring1R, width: ring1R * 2, height: ring1R * 2))
            r1.lineWidth = lw
            NSColor.black.withAlphaComponent(0.7).setStroke()
            r1.stroke()

            // ring 2 (faint)
            let r2 = NSBezierPath(ovalIn: CGRect(x: c.x - ring2R, y: c.y - ring2R, width: ring2R * 2, height: ring2R * 2))
            r2.lineWidth = lw * 0.85
            NSColor.black.withAlphaComponent(0.4).setStroke()
            r2.stroke()

            return true
        }
        img.isTemplate = true
        return img
    }
}
