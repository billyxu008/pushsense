import Foundation
import CoreGraphics

/// Global push-to-talk watcher for physical right Option. This is the same
/// CGEventTap approach proven in the Electron native helper.
final class Hotkey {
    private let targetKeycode: Int64
    private let flagMask: UInt64
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    init(keycode: Int64 = 61, flagMask: UInt64 = CGEventFlags.maskAlternate.rawValue) {
        self.targetKeycode = keycode
        self.flagMask = flagMask
    }

    /// Returns false only when macOS denies the event tap.
    func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let watcher = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            RuntimeLog.write("CGEventTap creation failed for keycode \(targetKeycode)")
            return false
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        RuntimeLog.write("CGEventTap ready keycode=\(targetKeycode) flagMask=\(flagMask)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            RuntimeLog.write("CGEventTap disabled (\\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == targetKeycode else { return }
        let down = (event.flags.rawValue & flagMask) != 0
        if down && !isDown {
            isDown = true
            RuntimeLog.write("hotkey(\(targetKeycode)) DOWN")
            // CGEventTap callbacks have a strict time budget. Starting an
            // AVAudioEngine can take hundreds of milliseconds; doing it here
            // makes macOS disable the global tap until another UI event wakes
            // it. Return from the callback first, then record on the main
            // queue in event order.
            DispatchQueue.main.async { [weak self] in self?.onDown?() }
        } else if !down && isDown {
            isDown = false
            RuntimeLog.write("hotkey(\(targetKeycode)) UP")
            DispatchQueue.main.async { [weak self] in self?.onUp?() }
        }
    }
}
