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
