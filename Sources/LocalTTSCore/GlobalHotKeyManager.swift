import Carbon
import Foundation

public struct GlobalKeyboardShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let displayText: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayText: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayText = displayText
    }

    public static let optionSpace = GlobalKeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        displayText: "Option-Space"
    )
}

@MainActor
public final class GlobalHotKeyManager: ObservableObject {
    @Published public private(set) var isRegistered = false
    @Published public private(set) var errorMessage: String?

    public var onHotKey: (@MainActor @Sendable () -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    public init() {}

    public func register(_ shortcut: GlobalKeyboardShortcut = .optionSpace) {
        unregister()
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: fourCharCode("LTTS"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKey = ref
            isRegistered = true
            errorMessage = nil
        } else {
            isRegistered = false
            errorMessage = "Could not register \(shortcut.displayText) (status \(status))"
        }
    }

    public func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        isRegistered = false
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                Task { @MainActor in
                    manager.onHotKey?()
                }

                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }

    private func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { partial, byte in
            (partial << 8) + OSType(byte)
        }
    }
}
