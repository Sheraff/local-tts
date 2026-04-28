import Foundation
import LocalTTSCore

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedVoiceID: String {
        didSet { defaults.set(selectedVoiceID, forKey: Keys.selectedVoiceID) }
    }

    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: Keys.speed) }
    }

    @Published var idleUnloadMinutes: Double {
        didSet { defaults.set(idleUnloadMinutes, forKey: Keys.idleUnloadMinutes) }
    }

    @Published var hotKeyEnabled: Bool {
        didSet {
            defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled)
            onHotKeySettingsChanged?()
        }
    }

    @Published var shortcut: GlobalKeyboardShortcut {
        didSet {
            defaults.set(shortcut.keyCode, forKey: Keys.shortcutKeyCode)
            defaults.set(shortcut.carbonModifiers, forKey: Keys.shortcutCarbonModifiers)
            defaults.set(shortcut.displayText, forKey: Keys.shortcutDisplayText)
            onHotKeySettingsChanged?()
        }
    }

    var onHotKeySettingsChanged: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedVoiceID = defaults.string(forKey: Keys.selectedVoiceID) ?? "af_heart"

        let storedSpeed = defaults.double(forKey: Keys.speed)
        speed = storedSpeed > 0 ? storedSpeed : 1.0

        let storedIdle = defaults.double(forKey: Keys.idleUnloadMinutes)
        idleUnloadMinutes = storedIdle > 0 ? storedIdle : 10

        if defaults.object(forKey: Keys.hotKeyEnabled) == nil {
            hotKeyEnabled = true
        } else {
            hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        }

        let storedKeyCode = (defaults.object(forKey: Keys.shortcutKeyCode) as? NSNumber)?.uint32Value
        let storedModifiers = (defaults.object(forKey: Keys.shortcutCarbonModifiers) as? NSNumber)?.uint32Value
        let storedDisplayText = defaults.string(forKey: Keys.shortcutDisplayText)
        if let storedKeyCode, let storedModifiers, let storedDisplayText {
            shortcut = GlobalKeyboardShortcut(
                keyCode: storedKeyCode,
                carbonModifiers: storedModifiers,
                displayText: storedDisplayText
            )
        } else {
            shortcut = .optionSpace
        }
    }

    private enum Keys {
        static let selectedVoiceID = "selectedVoiceID"
        static let speed = "speed"
        static let idleUnloadMinutes = "idleUnloadMinutes"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutCarbonModifiers = "shortcutCarbonModifiers"
        static let shortcutDisplayText = "shortcutDisplayText"
    }
}
