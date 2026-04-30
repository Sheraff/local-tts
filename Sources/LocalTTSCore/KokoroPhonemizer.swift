import Foundation
import MisakiSwift

final class KokoroPhonemizer: @unchecked Sendable {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var americanG2P: EnglishG2P?
    nonisolated(unsafe) private static var britishG2P: EnglishG2P?

    func phonemize(_ text: String, british: Bool) throws -> String {
        let phonemes = Self.withLock {
            let normalized = Self.preprocess(text)
            let g2p = Self.g2p(british: british)
            return g2p.phonemize(text: normalized).0
        }

        guard !phonemes.isEmpty else {
            throw SpeechEngineError.synthesisFailed("Kokoro English G2P produced no phonemes")
        }
        return phonemes
    }

    static var backendDescription: String {
        "MisakiSwift"
    }

    static var dataPathDescription: String {
        "MisakiSwift package resources"
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func g2p(british: Bool) -> EnglishG2P {
        if british {
            if let britishG2P {
                return britishG2P
            }
            let g2p = EnglishG2P(british: true, useFallbackNetwork: false)
            britishG2P = g2p
            return g2p
        }

        if let americanG2P {
            return americanG2P
        }
        let g2p = EnglishG2P(british: false, useFallbackNetwork: false)
        americanG2P = g2p
        return g2p
    }

    private static func preprocess(_ input: String) -> String {
        var result = input
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "«", with: "“")
            .replacingOccurrences(of: "»", with: "”")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "(", with: "«")
            .replacingOccurrences(of: ")", with: "»")
            .replacingOccurrences(of: "、", with: ", ")
            .replacingOccurrences(of: "。", with: ". ")
            .replacingOccurrences(of: "！", with: "! ")
            .replacingOccurrences(of: "，", with: ", ")
            .replacingOccurrences(of: "：", with: ": ")
            .replacingOccurrences(of: "；", with: "; ")
            .replacingOccurrences(of: "？", with: "? ")

        result = regexReplace(result, pattern: #"[^\S \n]"#, replacement: " ")
        result = regexReplace(result, pattern: #"  +"#, replacement: " ")
        result = regexReplace(result, pattern: #"(?m)^\s+$"#, replacement: "")
        result = regexReplace(result, pattern: #"\bD[Rr]\.(?= [A-Z])"#, replacement: "Doctor")
        result = regexReplace(result, pattern: #"\b(?:Mr\.|MR\.(?= [A-Z]))"#, replacement: "Mister")
        result = regexReplace(result, pattern: #"\b(?:Ms\.|MS\.(?= [A-Z]))"#, replacement: "Miss")
        result = regexReplace(result, pattern: #"\b(?:Mrs\.|MRS\.(?= [A-Z]))"#, replacement: "Mrs")
        result = regexReplace(result, pattern: #"(?i)\betc\.(?! [A-Z])"#, replacement: "etc")
        result = regexReplace(result, pattern: #"(?i)\b(y)eah?\b"#, replacement: "$1e'a")
        result = regexReplace(result, pattern: #"(?<=\d),(?=\d)"#, replacement: "")
        result = regexReplace(result, pattern: #"(?<=\d)-(?=\d)"#, replacement: " to ")
        result = regexReplace(result, pattern: #"(?<=\d)S"#, replacement: " S")
        result = regexReplace(result, pattern: #"(?<=[BCDFGHJ-NP-TV-Z])'?s\b"#, replacement: "'S")
        result = regexReplace(result, pattern: #"(?<=X')S\b"#, replacement: "s")
        result = regexReplace(result, pattern: #"(?<=[A-Z])\.(?=[A-Z])"#, replacement: "-")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ input: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }
}
