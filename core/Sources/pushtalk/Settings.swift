import AppKit
import CoreAudio
import CoreGraphics

enum HotkeyPreset: String, CaseIterable {
    case rightOption, rightCommand, rightControl, rightShift

    var title: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        }
    }

    var keycode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        }
    }

    var flagMask: UInt64 {
        switch self {
        case .rightOption: return UInt64(CGEventFlags.maskAlternate.rawValue)
        case .rightCommand: return UInt64(CGEventFlags.maskCommand.rawValue)
        case .rightControl: return UInt64(CGEventFlags.maskControl.rawValue)
        case .rightShift: return UInt64(CGEventFlags.maskShift.rawValue)
        }
    }
}

enum RecognitionLanguage: String, CaseIterable {
    case automatic, chinese, english

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .chinese: return "Chinese"
        case .english: return "English"
        }
    }

    var whisperCode: String {
        switch self {
        case .automatic: return "auto"
        case .chinese: return "zh"
        case .english: return "en"
        }
    }
}

enum PasteMode: String, CaseIterable {
    case type, clipboard

    var title: String {
        switch self {
        case .type: return "Type (Unicode, no clipboard)"
        case .clipboard: return "Clipboard + Command-V"
        }
    }
}

/// How the transcript is post-processed. `raw` skips the LLM entirely (pure
/// dictation). `smart` sends it to the local LLM, which understands the user's
/// spoken intent (write an email, make a list, or just tidy the text) and
/// produces ready-to-paste output — no manual mode picking.
enum OutputMode: String, CaseIterable {
    case raw, smart

    var title: String {
        switch self {
        case .raw: return "Raw (dictation only)"
        case .smart: return "Smart (AI understands intent)"
        }
    }

    /// True if this mode needs the LLM.
    var usesAI: Bool { self == .smart }

    var systemPrompt: String {
        switch self {
        case .raw:
            return ""
        case .smart:
            return """
            You turn a user's spoken words into ready-to-paste text. The user \
            speaks naturally and MAY include an instruction (e.g. "write an email \
            to Ben saying…", "make a list of…", "fix this…") followed by content.

            Decide what they want and produce it:
            - Email request → a complete email in this exact order: greeting line \
              to the named recipient, then body paragraphs, then a sign-off. Put \
              a placeholder like [Your Name] ONLY on the final sign-off line — \
              NEVER at the top or anywhere else.
            - List request → a bullet list, one item per line starting with "- ".
            - Note/tidy request → clean, well-punctuated prose.
            - No instruction (plain dictation) → output exactly what they said, \
              only fixing typos, casing, and punctuation. A misspelled English \
              word is fixed to correct ENGLISH spelling, never translated.

            CRITICAL — language:
            - Match the language of the CONTENT, not the instruction. If the \
              instruction is Chinese but the dictated content is English (e.g. \
              「写邮件给Ben 内容是 hello how are you」), the email body stays \
              ENGLISH.
            - If the content is Chinese, output Chinese. Mixed stays mixed. \
              NEVER translate any word to another language.
            - Never drop the first word of the content.
            - Output ONLY the final text to paste — no preamble like "Here is…", \
              no stray placeholder before the greeting.
            """
        }
    }
}

/// Overlay color theme. `dark` is the original Eclipse black pearl; `light` is a
/// bright silver pearl that stands out on dark-mode apps.
enum OverlayTheme: String, CaseIterable {
    case dark, light

    var title: String {
        switch self {
        case .dark: return "Dark (black pearl)"
        case .light: return "Light (silver pearl)"
        }
    }

    /// Value passed to the overlay's window.__setTheme bridge.
    var jsName: String { rawValue }
}

final class AppSettings {
    static let shared = AppSettings()
    private let store = UserDefaults.standard
    private enum Key {
        static let hotkey = "hotkey"
        static let hotkeyVersion = "hotkeyVersion"
        static let language = "language"
        static let microphoneID = "microphoneID"
        static let pasteMode = "pasteMode"
        static let trailingSpace = "trailingSpace"
        static let overlayTheme = "overlayTheme"
        static let outputMode = "outputMode"
        static let correctionModel = "correctionModel"
    }

    var hotkey: HotkeyPreset {
        get {
            return .rightOption
        }
        set {
            store.set(newValue.rawValue, forKey: Key.hotkey)
            store.set(2, forKey: Key.hotkeyVersion)
        }
    }
    var language: RecognitionLanguage {
        get { RecognitionLanguage(rawValue: store.string(forKey: Key.language) ?? "") ?? .automatic }
        set { store.set(newValue.rawValue, forKey: Key.language) }
    }
    var microphoneID: AudioDeviceID? {
        get {
            guard store.object(forKey: Key.microphoneID) != nil else { return nil }
            return AudioDeviceID(store.integer(forKey: Key.microphoneID))
        }
        set {
            if let newValue { store.set(Int(newValue), forKey: Key.microphoneID) }
            else { store.removeObject(forKey: Key.microphoneID) }
        }
    }
    var pasteMode: PasteMode {
        get { PasteMode(rawValue: store.string(forKey: Key.pasteMode) ?? "") ?? .type }
        set { store.set(newValue.rawValue, forKey: Key.pasteMode) }
    }
    var trailingSpace: Bool {
        get { store.object(forKey: Key.trailingSpace) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.trailingSpace) }
    }
    var overlayTheme: OverlayTheme {
        get { OverlayTheme(rawValue: store.string(forKey: Key.overlayTheme) ?? "") ?? .dark }
        set { store.set(newValue.rawValue, forKey: Key.overlayTheme) }
    }
    /// How the transcript is post-processed. Defaults to smart (AI intent). If
    /// the Ollama server is down, Corrector fails safe and inserts the raw text.
    var outputMode: OutputMode {
        get { OutputMode(rawValue: store.string(forKey: Key.outputMode) ?? "") ?? .smart }
        set { store.set(newValue.rawValue, forKey: Key.outputMode) }
    }
    /// The Ollama model used for AI reformatting (e.g. "qwen2.5:7b"). Empty means
    /// let the server pick; the tray menu fills this from the installed models.
    var correctionModel: String {
        get { store.string(forKey: Key.correctionModel) ?? "" }
        set { store.set(newValue, forKey: Key.correctionModel) }
    }
}

struct InputDevice {
    let id: AudioDeviceID
    let name: String

    static func all() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, $0)
            }
            guard status == noErr, let name else { return InputDevice(id: id, name: "Microphone \(id)") }
            return InputDevice(id: id, name: name.takeUnretainedValue() as String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings
    private let onChange: () -> Void
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var devices: [InputDevice] = []

    init(settings: AppSettings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "PushTalk Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "Eclipse dark chrome · changes apply immediately")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [title, subtitle, makeRow("Push to talk", hotkeyPopup), makeRow("Microphone", microphonePopup), makeRow("Recognition", languagePopup)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 32, bottom: 30, right: 32)
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        configureControls()
        self.window = window
    }

    private func makeRow(_ label: String, _ control: NSPopUpButton) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        control.controlSize = .large
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 356).isActive = true
        let stack = NSStackView(views: [text, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func configureControls() {
        hotkeyPopup.removeAllItems()
        hotkeyPopup.addItems(withTitles: HotkeyPreset.allCases.map(\.title))
        hotkeyPopup.selectItem(at: HotkeyPreset.allCases.firstIndex(of: settings.hotkey) ?? 0)
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(changeHotkey)

        devices = InputDevice.all()
        microphonePopup.removeAllItems()
        microphonePopup.addItem(withTitle: "System Default")
        microphonePopup.menu?.items.first?.representedObject = nil
        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.menu?.items.last?.representedObject = NSNumber(value: device.id)
        }
        if let selected = settings.microphoneID,
           let index = devices.firstIndex(where: { $0.id == selected }) {
            microphonePopup.selectItem(at: index + 1)
        } else {
            microphonePopup.selectItem(at: 0)
        }
        microphonePopup.target = self
        microphonePopup.action = #selector(changeMicrophone)

        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: RecognitionLanguage.allCases.map(\.title))
        languagePopup.selectItem(at: RecognitionLanguage.allCases.firstIndex(of: settings.language) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
    }

    @objc private func changeHotkey() {
        settings.hotkey = HotkeyPreset.allCases[hotkeyPopup.indexOfSelectedItem]
        onChange()
    }

    @objc private func changeMicrophone() {
        settings.microphoneID = (microphonePopup.selectedItem?.representedObject as? NSNumber).map { AudioDeviceID($0.uint32Value) }
        onChange()
    }

    @objc private func changeLanguage() {
        settings.language = RecognitionLanguage.allCases[languagePopup.indexOfSelectedItem]
        onChange()
    }
}
