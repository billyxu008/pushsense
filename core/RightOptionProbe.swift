import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "PushTalk Key Probe"
let label = NSTextField(labelWithString: "Press and release the physical Right Option key")
label.font = .systemFont(ofSize: 17, weight: .medium)
label.alignment = .center
label.frame = NSRect(x: 20, y: 55, width: 380, height: 30)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

var sawDown = false
NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
    let optionDown = event.modifierFlags.contains(.option)
    print("FLAGS_CHANGED keycode=\(event.keyCode) option=\(optionDown) raw=\(event.modifierFlags.rawValue)")
    fflush(stdout)
    if optionDown { sawDown = true }
    if sawDown && !optionDown {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { app.terminate(nil) }
    }
    return event
}

print("READY local key probe")
fflush(stdout)
app.run()
