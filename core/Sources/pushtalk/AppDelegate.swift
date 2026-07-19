import AppKit
import CoreAudio
import CoreGraphics

/// Menubar-only app. Owns the status item and the Controller.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller?
    private let overlay = Overlay()
    private let modelPath: String
    private let settings = AppSettings.shared
    private var modelReady = false

    init(modelPath: String) {
        self.modelPath = modelPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeLog.write("app launched pid=\(ProcessInfo.processInfo.processIdentifier)")
        NSApp.setActivationPolicy(.accessory) // no dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(state: .idle)
        rebuildMenu(status: "Loading model…")

        // Load the 1.6GB model OFF the main thread so the menubar item paints
        // immediately instead of freezing during load.
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let ctl = Controller(modelPath: self.modelPath, settings: self.settings)
            DispatchQueue.main.async {
                guard let ctl = ctl else {
                    self.rebuildMenu(status: "⚠ Model failed to load")
                    return
                }
                self.setupController(ctl)
            }
        }
    }

    private func setupController(_ ctl: Controller) {
        RuntimeLog.write("model loaded; configuring hotkey")
        controller = ctl
        modelReady = true
        overlay.setTheme(settings.overlayTheme.jsName)
        ctl.onStateChange = { [weak self] s in self?.onState(s) }
        ctl.onLevel = { [weak self] lvl in self?.overlay.setLevel(lvl) }

        // A listen-only CGEventTap requires Input Monitoring, not the older
        // Accessibility permission. Check it explicitly: a stale TCC row can
        // still make tapCreate succeed while delivering no keyboard events.
        guard CGPreflightListenEventAccess() else {
            RuntimeLog.write("Input Monitoring not granted")
            rebuildMenu(status: "⚠ Allow Input Monitoring")
            // TCC ignores a privacy request from an inactive LSUIElement app.
            // Briefly activate it so macOS can present the real allow/deny
            // prompt, rather than leaving the user on an empty settings list.
            NSApp.activate(ignoringOtherApps: true)
            let requestAccepted = CGRequestListenEventAccess()
            RuntimeLog.write("Input Monitoring request returned \(requestAccepted)")
            if !requestAccepted {
                openInputMonitoringSettings()
            }
            return
        }
        RuntimeLog.write("Input Monitoring granted")

        // Input Monitoring lets us observe Right-Option. Posting the
        // recognized Unicode back into another app is a separate TCC service:
        // Accessibility. Without this check CGEvent.post simply disappears.
        if !AXIsProcessTrusted() {
            // TCC will not reliably present an Accessibility prompt while a
            // menu-bar-only app is inactive. Activate before the *first*
            // prompted check (rather than after it has already been skipped).
            NSApp.activate(ignoringOtherApps: true)
            let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let accessibilityGranted = AXIsProcessTrustedWithOptions(axOptions)
            guard accessibilityGranted else {
                RuntimeLog.write("Accessibility not granted; text injection unavailable")
                rebuildMenu(status: "⚠ Allow Accessibility to type text")
                openAccessibilitySettings()
                return
            }
        }
        RuntimeLog.write("Accessibility granted")

        ctl.requestMic { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                self.rebuildMenu(status: "⚠ Microphone denied")
            }
            if ctl.start() {
                RuntimeLog.write("hotkey started")
                self.rebuildMenu(status: "Ready — hold Right-Option")
            } else {
                RuntimeLog.write("hotkey start failed")
                self.rebuildMenu(status: "⚠ Input Monitoring needed")
                self.openInputMonitoringSettings()
            }
        }
    }

    private func onState(_ s: Controller.State) {
        updateIcon(state: s)
        switch s {
        case .idle:
            rebuildMenu(status: "Ready — hold Right-Option")
            overlay.show(.hidden)
        case .recording:
            rebuildMenu(status: "● Recording…")
            overlay.show(.listening)
        case .transcribing:
            rebuildMenu(status: "Transcribing…")
            overlay.show(.transcribing)
        }
    }

    private func updateIcon(state: Controller.State) {
        guard let button = statusItem.button else { return }
        let img = HaloIcon.image(size: 18)
        img.isTemplate = true
        button.image = img
        if button.image == nil {
            button.image = NSImage(systemSymbolName: "dot.circle", accessibilityDescription: "PushTalk")
            button.image?.isTemplate = true
        }
        button.imagePosition = .imageLeading
        switch state {
        case .idle: button.title = ""
        case .recording: button.title = "rec"
        case .transcribing: button.title = "…"
        }
    }

    private func rebuildMenu(status: String) {
        let menu = NSMenu()
        let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())

        menu.addItem(submenuItem(title: "Hotkey: \(settings.hotkey.title)", items: HotkeyPreset.allCases.map { preset in
            selectableItem(title: preset.title, selected: settings.hotkey == preset, value: preset.rawValue, action: #selector(changeHotkey(_:)))
        }))
        let microphoneItems: [NSMenuItem] = [
            selectableItem(title: "System Default", selected: settings.microphoneID == nil, value: nil, action: #selector(changeMicrophone(_:)))
        ] + InputDevice.all().map { device in
            selectableItem(title: device.name, selected: settings.microphoneID == device.id, value: NSNumber(value: device.id), action: #selector(changeMicrophone(_:)))
        }
        menu.addItem(submenuItem(title: "Microphone", items: microphoneItems))
        menu.addItem(submenuItem(title: "Language: \(settings.language.whisperCode)", items: RecognitionLanguage.allCases.map { language in
            selectableItem(title: language.title, selected: settings.language == language, value: language.rawValue, action: #selector(changeLanguage(_:)))
        }))
        menu.addItem(submenuItem(title: "Paste mode: \(settings.pasteMode.rawValue)", items: PasteMode.allCases.map { mode in
            selectableItem(title: mode.title, selected: settings.pasteMode == mode, value: mode.rawValue, action: #selector(changePasteMode(_:)))
        }))
        menu.addItem(submenuItem(title: "Overlay theme: \(settings.overlayTheme.rawValue)", items: OverlayTheme.allCases.map { theme in
            selectableItem(title: theme.title, selected: settings.overlayTheme == theme, value: theme.rawValue, action: #selector(changeOverlayTheme(_:)))
        }))
        let trailing = NSMenuItem(title: "Trailing space", action: #selector(toggleTrailingSpace(_:)), keyEquivalent: "")
        trailing.target = self
        trailing.state = settings.trailingSpace ? .on : .off
        menu.addItem(trailing)
        menu.addItem(.separator())
        let readiness = NSMenuItem(title: modelReady ? "✓ Model whisper ready" : "⚠ Model unavailable", action: nil, keyEquivalent: "")
        readiness.isEnabled = false
        menu.addItem(readiness)
        let configFolder = NSMenuItem(title: "Open config folder", action: #selector(openConfigFolder), keyEquivalent: "")
        configFolder.target = self
        menu.addItem(configFolder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PushTalk", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    private func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func selectableItem(title: String, selected: Bool, value: Any?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = selected ? .on : .off
        return item
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = HotkeyPreset(rawValue: rawValue) else { return }
        settings.hotkey = value
        _ = controller?.restartHotkey()
        rebuildMenu(status: "Ready — hold \(value.title)")
    }

    @objc private func changeMicrophone(_ sender: NSMenuItem) {
        settings.microphoneID = (sender.representedObject as? NSNumber).map { AudioDeviceID($0.uint32Value) }
        controller?.refreshRecordingSettings()
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = RecognitionLanguage(rawValue: rawValue) else { return }
        settings.language = value
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func changePasteMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = PasteMode(rawValue: rawValue) else { return }
        settings.pasteMode = value
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func toggleTrailingSpace(_ sender: NSMenuItem) {
        settings.trailingSpace.toggle()
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func changeOverlayTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = OverlayTheme(rawValue: rawValue) else { return }
        settings.overlayTheme = value
        overlay.setTheme(value.jsName)
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func openConfigFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("PushTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        NSWorkspace.shared.open(base)
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
