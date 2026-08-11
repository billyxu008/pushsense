import AppKit
import CoreAudio
import CoreGraphics
import ServiceManagement

/// Menubar-only app. Owns the status item and the Controller.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller?
    private let overlay = Overlay()
    /// nil until a model is installed. Mutable so a download can bring the app
    /// to life without a relaunch.
    private var modelPath: String?
    private let settings = AppSettings.shared
    private var modelReady = false
    private var aiModels: [String] = []
    /// Non-nil while a download is in flight; drives the menu's progress line.
    private var downloadStatus: String?

    init(modelPath: String?) {
        self.modelPath = modelPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeLog.write("app launched pid=\(ProcessInfo.processInfo.processIdentifier)")
        NSApp.setActivationPolicy(.accessory) // no dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(state: .idle)
        loadModel()
    }

    /// Load whichever model is currently active, or prompt for a download if none
    /// is installed. Safe to call again after a download or a model switch.
    private func loadModel() {
        modelPath = modelPath ?? ModelStore.resolveActiveModelPath(settings: settings)

        guard let path = modelPath else {
            modelReady = false
            controller = nil
            rebuildMenu(status: "No model — choose one to download")
            return
        }

        modelReady = false
        rebuildMenu(status: "Loading model…")

        // Load the 1.6GB model OFF the main thread so the menubar item paints
        // immediately instead of freezing during load.
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let ctl = Controller(modelPath: path, settings: self.settings)
            DispatchQueue.main.async {
                guard let ctl = ctl else {
                    // The file is missing or corrupt. Clear it so the menu offers
                    // a re-download rather than silently failing forever.
                    RuntimeLog.write("model failed to load: \(path)")
                    self.modelPath = nil
                    self.rebuildMenu(status: "⚠ Model failed to load — re-download")
                    return
                }
                self.setupController(ctl)
            }
        }
    }

    /// Download a model, then load it automatically when it lands.
    private func download(_ model: WhisperModel) {
        downloadStatus = "Starting…"
        rebuildMenu(status: "Downloading \(model.title)")

        ModelDownloader.shared.start(model) { [weak self] progress in
            guard let self = self else { return }
            switch progress {
            case let .downloading(fraction, received, total):
                let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
                self.downloadStatus = "\(Int(fraction * 100))% · \(mb(received))/\(mb(total)) MB"
                self.rebuildMenu(status: "Downloading \(model.title)")

            case .finished:
                self.downloadStatus = nil
                self.settings.whisperModelID = model.id
                // Force re-resolution now that the file exists, then load it.
                self.modelPath = nil
                self.loadModel()

            case let .failed(message):
                self.downloadStatus = nil
                RuntimeLog.write("download failed: \(message)")
                self.rebuildMenu(status: "⚠ Download failed — \(message)")
                self.notify(title: "PushSense download failed", body: message)

            case .cancelled:
                self.downloadStatus = nil
                self.rebuildMenu(status: self.modelReady ? "Ready" : "No model — choose one to download")
            }
        }
    }

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setupController(_ ctl: Controller) {
        RuntimeLog.write("model loaded; configuring hotkey")
        controller = ctl
        modelReady = true
        overlay.setTheme(settings.overlayTheme.jsName)
        // Fetch the model list, then preload the LLM only if AI mode is already
        // on — so idle users pay no memory cost for a feature they aren't using.
        DispatchQueue.global().async { [weak self] in
            let models = Corrector.listModels()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.aiModels = models
                self.rebuildMenu(status: "Ready — hold \(self.settings.hotkey.title)")
                if self.settings.outputMode.usesAI {
                    Corrector.loadModel(self.effectiveModel())
                }
            }
        }
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
            button.image = NSImage(systemSymbolName: "dot.circle", accessibilityDescription: "PushSense")
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
        let launchAtLogin = NSMenuItem(
            title: "Launch at login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(submenuItem(title: "Output mode: \(settings.outputMode.title)", items: OutputMode.allCases.map { mode in
            selectableItem(title: mode.title, selected: settings.outputMode == mode, value: mode.rawValue, action: #selector(changeOutputMode(_:)))
        }))
        // AI model picker (Ollama). Lists installed models; "Server default" lets
        // Ollama choose. Populated lazily from `aiModels`.
        var modelItems: [NSMenuItem] = [
            selectableItem(title: "Server default", selected: settings.correctionModel.isEmpty, value: "", action: #selector(changeAIModel(_:)))
        ]
        modelItems += aiModels.map { name in
            selectableItem(title: name, selected: settings.correctionModel == name, value: name, action: #selector(changeAIModel(_:)))
        }
        modelItems.append(.separator())
        modelItems.append({ let i = NSMenuItem(title: "Refresh models", action: #selector(refreshAIModels), keyEquivalent: ""); i.target = self; return i }())
        menu.addItem(submenuItem(title: "AI model: \(settings.correctionModel.isEmpty ? "default" : settings.correctionModel)", items: modelItems))
        menu.addItem(.separator())

        // Whisper model: download / switch / remove. This is the only place a
        // model gets installed — the app ships without one.
        menu.addItem(submenuItem(title: "Speech model: \(activeModelTitle())", items: whisperModelItems()))

        let readiness = NSMenuItem(title: modelReady ? "✓ Speech model ready" : "⚠ No speech model", action: nil, keyEquivalent: "")
        readiness.isEnabled = false
        menu.addItem(readiness)
        if let downloadStatus {
            let progress = NSMenuItem(title: "   ↓ \(downloadStatus)", action: nil, keyEquivalent: "")
            progress.isEnabled = false
            menu.addItem(progress)
            let cancel = NSMenuItem(title: "Cancel download", action: #selector(cancelDownload), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        let configFolder = NSMenuItem(title: "Open config folder", action: #selector(openConfigFolder), keyEquivalent: "")
        configFolder.target = self
        menu.addItem(configFolder)
        let modelFolder = NSMenuItem(title: "Open model folder", action: #selector(openModelFolder), keyEquivalent: "")
        modelFolder.target = self
        menu.addItem(modelFolder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PushSense", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    private func activeModelTitle() -> String {
        guard let path = modelPath else { return "none" }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return WhisperModel.all.first { $0.id == name }?.title ?? name
    }

    /// One row per catalog model: installed ones are selectable, missing ones
    /// offer a download. Everything is disabled while a download is running so
    /// two transfers can't overlap.
    private func whisperModelItems() -> [NSMenuItem] {
        let busy = ModelDownloader.shared.isDownloading
        var items: [NSMenuItem] = []

        for model in WhisperModel.all {
            let installed = ModelStore.isInstalled(model)
            let isActive = installed && modelPath == ModelStore.url(for: model).path
            let title = installed ? model.title : "\(model.title)  ⤓ Download"
            let item = NSMenuItem(
                title: title,
                action: installed ? #selector(selectWhisperModel(_:)) : #selector(downloadWhisperModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.id
            item.state = isActive ? .on : .off
            item.toolTip = model.note
            item.isEnabled = !busy
            items.append(item)
        }

        items.append(.separator())
        let installedModels = ModelStore.installed
        if installedModels.isEmpty {
            let hint = NSMenuItem(title: "Downloads go to Application Support", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            items.append(hint)
        } else {
            let removeItems = installedModels.map { model -> NSMenuItem in
                let i = NSMenuItem(title: model.title, action: #selector(removeWhisperModel(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = model.id
                i.isEnabled = !busy
                return i
            }
            items.append(submenuItem(title: "Remove downloaded…", items: removeItems))
        }
        return items
    }

    @objc private func downloadWhisperModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.id == id }) else { return }
        download(model)
    }

    @objc private func selectWhisperModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.id == id }),
              ModelStore.isInstalled(model) else { return }
        settings.whisperModelID = id
        // Drop the old context and load the newly chosen file.
        controller = nil
        modelPath = ModelStore.url(for: model).path
        loadModel()
    }

    @objc private func removeWhisperModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove \(model.title)?"
        alert.informativeText = "The file is deleted from disk. You can download it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasActive = modelPath == ModelStore.url(for: model).path
        do {
            try ModelStore.delete(model)
        } catch {
            notify(title: "Could not remove model", body: error.localizedDescription)
            return
        }
        if wasActive {
            // Release the loaded context, then fall back to another model if any.
            controller = nil
            modelReady = false
            modelPath = nil
            loadModel()
        } else {
            rebuildMenu(status: modelReady ? "Ready — hold \(settings.hotkey.title)" : "No model")
        }
    }

    @objc private func cancelDownload() {
        ModelDownloader.shared.cancel()
    }

    @objc private func openModelFolder() {
        try? ModelStore.ensureDirectory()
        NSWorkspace.shared.open(ModelStore.directory)
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

    /// Uses the app bundle itself as the login item. Unlike a hand-written
    /// LaunchAgent this appears in macOS Login Items and is managed entirely
    /// by the system, including the user-visible approval state.
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
        } catch {
            RuntimeLog.write("launch-at-login update failed: \(error.localizedDescription)")
            notify(
                title: "Couldn't update Launch at Login",
                body: "Check System Settings → General → Login Items, then try again."
            )
            rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
        }
    }

    @objc private func changeOutputMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = OutputMode(rawValue: rawValue) else { return }
        let wasAI = settings.outputMode.usesAI
        settings.outputMode = value
        // Resource management: only keep the LLM in memory while AI mode is on.
        if value.usesAI && !wasAI {
            Corrector.loadModel(effectiveModel())
        } else if !value.usesAI && wasAI {
            Corrector.unloadModel(effectiveModel())
        }
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func changeAIModel(_ sender: NSMenuItem) {
        let previous = settings.correctionModel
        settings.correctionModel = (sender.representedObject as? String) ?? ""
        // If AI is active, swap resident models: unload the old, load the new.
        if settings.outputMode.usesAI {
            if !previous.isEmpty && previous != settings.correctionModel {
                Corrector.unloadModel(previous)
            }
            Corrector.loadModel(settings.correctionModel)
        }
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    /// The model to actually load/unload/use. If the user picked "Server default"
    /// (empty), fall back to the first installed model so load/unload still work.
    private func effectiveModel() -> String {
        if !settings.correctionModel.isEmpty { return settings.correctionModel }
        return aiModels.first ?? ""
    }

    @objc private func refreshAIModels() {
        DispatchQueue.global().async { [weak self] in
            let models = Corrector.listModels()
            DispatchQueue.main.async {
                self?.aiModels = models
                self?.rebuildMenu(status: "Ready — hold \(self?.settings.hotkey.title ?? "")")
            }
        }
    }

    @objc private func changeOverlayTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let value = OverlayTheme(rawValue: rawValue) else { return }
        settings.overlayTheme = value
        overlay.setTheme(value.jsName)
        rebuildMenu(status: "Ready — hold \(settings.hotkey.title)")
    }

    @objc private func openConfigFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("PushSense", isDirectory: true)
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

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave the LLM resident in memory after we're gone.
        if settings.outputMode.usesAI {
            Corrector.unloadModel(effectiveModel())
        }
    }
}
