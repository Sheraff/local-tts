import AppKit
import ApplicationServices
import Foundation

public enum CaptureSource: String, Sendable {
    case accessibilitySelection = "Selection"
    case clipboard = "Clipboard"
    case articleURL = "Article URL"
    case browserTab = "Browser Tab"
    case manual = "Manual"
    case none = "None"
}

public struct CapturedText: Sendable {
    public let text: String
    public let source: CaptureSource

    public init(text: String, source: CaptureSource) {
        self.text = text
        self.source = source
    }
}

@MainActor
public final class TextCaptureService {
    public init() {}

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func capturePreferredText() -> CapturedText? {
        if let selectedText = selectedTextFromFocusedElement(), !selectedText.isEmpty {
            return CapturedText(text: selectedText, source: .accessibilitySelection)
        }

        if let clipboardText = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !clipboardText.isEmpty
        {
            return CapturedText(text: clipboardText, source: .clipboard)
        }

        return nil
    }

    private func selectedTextFromFocusedElement() -> String? {
        guard isAccessibilityTrusted else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedError == .success, let focusedValue else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )

        guard selectedError == .success else {
            return nil
        }

        return (selectedValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
