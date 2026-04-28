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
        let prepared = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")

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
}
