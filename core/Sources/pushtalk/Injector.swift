import AppKit
import Foundation
import CoreGraphics

/// Types text into the focused app by synthesizing Unicode keyboard events.
/// This is the only reliable way to inject arbitrary characters — including
/// CJK/emoji, which have no physical key — without touching the clipboard.
enum Injector {
    static func insert(_ text: String, mode: PasteMode, trailingSpace: Bool) {
        let out = trailingSpace ? text + " " : text
        if out.isEmpty { return }

        if mode == .clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out, forType: .string)
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyCode: CGKeyCode = 9 // V
            if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
                down.flags = .maskCommand
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                up.flags = .maskCommand
                up.post(tap: .cghidEventTap)
            }
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let scalars = Array(out.unicodeScalars)
        let batchSize = 20
        var idx = 0

        while idx < scalars.count {
            let end = min(idx + batchSize, scalars.count)
            var utf16: [UniChar] = []
            for s in scalars[idx..<end] {
                for u in String(s).utf16 { utf16.append(u) }
            }

            // The Unicode payload goes ONLY on key-down. A key-up carrying the
            // same string makes many apps insert the text twice. The key-up is
            // sent empty just to keep the event pair balanced.
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            idx = end
            usleep(1500)
        }
    }
}
