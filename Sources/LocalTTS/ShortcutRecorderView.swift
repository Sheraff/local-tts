import AppKit
import Carbon
import LocalTTSCore
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: GlobalKeyboardShortcut

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        ShortcutRecorderControl(shortcut: shortcut) { newShortcut in
            shortcut = newShortcut
        }
    }

    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {
        nsView.shortcut = shortcut
    }
}

final class ShortcutRecorderControl: NSView {
    var shortcut: GlobalKeyboardShortcut {
        didSet {
            updateLabel()
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let onChange: (GlobalKeyboardShortcut) -> Void
    private var isRecording = false
    private var validationMessage: String?

    init(shortcut: GlobalKeyboardShortcut, onChange: @escaping (GlobalKeyboardShortcut) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateLabel()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        validationMessage = nil
        updateLabel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            validationMessage = nil
            updateLabel()
            return
        }

        guard let newShortcut = GlobalKeyboardShortcut(event: event) else {
            validationMessage = "Use Command, Option, or Control with a key"
            updateLabel()
            return
        }

        shortcut = newShortcut
        onChange(newShortcut)
        isRecording = false
        validationMessage = nil
        updateLabel()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        validationMessage = nil
        updateLabel()
        return true
    }

    private func updateLabel() {
        if let validationMessage {
            label.stringValue = validationMessage
            label.textColor = .systemRed
        } else if isRecording {
            label.stringValue = "Press shortcut..."
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = shortcut.displayText
            label.textColor = .labelColor
        }
    }
}

private extension GlobalKeyboardShortcut {
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var carbonModifiers: UInt32 = 0
        var displayParts: [String] = []

        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            displayParts.append("⌃")
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            displayParts.append("⌥")
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            displayParts.append("⇧")
        }
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            displayParts.append("⌘")
        }

        let hasRequiredModifier = modifiers.contains(.command)
            || modifiers.contains(.option)
            || modifiers.contains(.control)
        guard hasRequiredModifier else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        displayParts.append(Self.displayName(for: event))
        self.init(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            displayText: displayParts.joined()
        )
    }

    static func displayName(for event: NSEvent) -> String {
        if let character = event.charactersIgnoringModifiers?.uppercased(),
           character.count == 1,
           character.first?.isLetter == true || character.first?.isNumber == true
        {
            return character
        }

        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Delete:
            return "Delete"
        case kVK_Escape:
            return "Esc"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_F1...kVK_F20:
            return "F\(Int(event.keyCode) - kVK_F1 + 1)"
        default:
            return "Key \(event.keyCode)"
        }
    }
}
