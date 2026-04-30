import Foundation

public struct TextNormalizer: Sendable {
    private let removableShortLines: Set<String> = [
        "advertisement",
        "all rights reserved",
        "cookie policy",
        "home",
        "newsletter",
        "privacy policy",
        "related articles",
        "share",
        "sign in",
        "subscribe",
        "terms of service",
    ]

    public init() {}

    public func normalize(_ input: String) -> String {
        let prepared = prepareInput(input)

        var output: [String] = []
        var previousWasBlank = false

        for rawLine in prepared.components(separatedBy: "\n") {
            let line = collapseInlineWhitespace(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))

            if line.isEmpty {
                if !previousWasBlank, !output.isEmpty {
                    output.append("")
                    previousWasBlank = true
                }
                continue
            }

            if shouldRemove(line) {
                continue
            }

            output.append(line)
            previousWasBlank = false
        }

        while output.last == "" {
            output.removeLast()
        }

        return output.joined(separator: "\n")
    }

    private func shouldRemove(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        if line.count <= 80, removableShortLines.contains(lowercased) {
            return true
        }

        if line.count <= 60, lowercased.hasPrefix("advertisement") {
            return true
        }

        return false
    }

    private func collapseInlineWhitespace(_ line: String) -> String {
        line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    private func prepareInput(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)

        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                output.unicodeScalars.append(scalar)
            case 0x0D:
                output.append("\n")
            case 0x09, 0x20, 0x00A0:
                output.append(" ")
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFD:
                continue
            case 0xFFFC:
                output.append("\n")
            default:
                if shouldDrop(scalar) {
                    continue
                }
                output.unicodeScalars.append(scalar)
            }
        }

        return output
    }

    private func shouldDrop(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            true
        default:
            false
        }
    }
}
