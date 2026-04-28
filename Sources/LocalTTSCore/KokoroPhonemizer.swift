import Foundation
import libespeak_ng

final class KokoroPhonemizer: @unchecked Sendable {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var isInitialized = false

    func phonemize(_ text: String, british: Bool) throws -> String {
        let phonemes = try Self.withLock {
            try Self.ensureInitialized()
            try Self.setVoice(british: british)
            return try Self.phonemizeForKokoro(text, british: british)
        }

        guard !phonemes.isEmpty else {
            throw SpeechEngineError.synthesisFailed("Kokoro phonemizer produced no phonemes")
        }
        return phonemes
    }

    static var backendDescription: String {
        "Native eSpeak NG"
    }

    static var dataRootURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("eSpeakNG", isDirectory: true)
    }

    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func ensureInitialized() throws {
        guard !isInitialized else {
            return
        }

        let root = dataRootURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try EspeakLib.ensureBundleInstalled(inRoot: root)

        espeak_ng_InitializePath(root.path)

        var context: espeak_ng_ERROR_CONTEXT?
        try check(espeak_ng_Initialize(&context), operation: "initialize eSpeak NG")
        try check(
            espeak_ng_InitializeOutput(ENOUTPUT_MODE_SYNCHRONOUS, 0, nil),
            operation: "initialize eSpeak NG output"
        )

        isInitialized = true
    }

    private static func setVoice(british: Bool) throws {
        let voice = british ? "en" : "en-us"
        try voice.withCString { voiceName in
            try check(espeak_ng_SetVoiceByName(voiceName), operation: "set eSpeak NG voice \(voice)")
        }
    }

    private static func phonemizeForKokoro(_ input: String, british: Bool) throws -> String {
        let normalized = preprocess(input)
        let parts = splitPreservingPunctuation(normalized)
        let phonemes = try parts.map { part -> String in
            if part.isPunctuation {
                return part.text
            }
            return try phonemizePlainText(part.text)
        }.joined()
        return normalizeEspeakPhonemes(phonemes, british: british)
    }

    private static func phonemizePlainText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return text
        }

        let phonemeMode = CInt(espeakPHONEMES_IPA | espeakPHONEMES_TIE | (0x200d << 8))
        return trimmed.withCString { textCString in
            var textPointer: UnsafeRawPointer? = UnsafeRawPointer(textCString)
            var clauses: [String] = []

            while textPointer != nil {
                let previousPointer = textPointer
                guard let output = espeak_TextToPhonemes(&textPointer, espeakCHARS_UTF8, phonemeMode) else {
                    break
                }

                let clause = String(cString: output).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty {
                    clauses.append(clause)
                }

                if textPointer == previousPointer {
                    break
                }
            }

            return clauses.joined(separator: " ")
        }
    }

    private static func splitPreservingPunctuation(_ input: String) -> [(isPunctuation: Bool, text: String)] {
        let punctuation = CharacterSet(charactersIn: ";:,.!?¡¿—…\"«»“”(){}[]")
        var parts: [(Bool, String)] = []
        var current = ""
        var currentIsPunctuation: Bool?

        for scalar in input.unicodeScalars {
            let isPunctuation = punctuation.contains(scalar)
            if let currentIsPunctuation, currentIsPunctuation != isPunctuation {
                if !current.isEmpty {
                    parts.append((currentIsPunctuation, current))
                }
                current = ""
            }

            current.unicodeScalars.append(scalar)
            currentIsPunctuation = isPunctuation
        }

        if let currentIsPunctuation, !current.isEmpty {
            parts.append((currentIsPunctuation, current))
        }

        return parts
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

    private static func check(_ status: espeak_ng_STATUS, operation: String) throws {
        guard status == ENS_OK else {
            var buffer = [CChar](repeating: 0, count: 256)
            espeak_ng_GetStatusCodeMessage(status, &buffer, buffer.count)
            let message = buffer.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.map(String.init(cString:)) ?? "Unknown eSpeak NG error"
            }
            throw SpeechEngineError.synthesisFailed("Could not \(operation): \(message)")
        }
    }

    private static func normalizeEspeakPhonemes(_ text: String, british: Bool) -> String {
        let untied = String(text.unicodeScalars.filter { scalar in
            scalar.value != 0x200d && scalar.value != 0x0361
        })

        var phonemes = untied
            .replacingOccurrences(of: "kəkˈoːɹoʊ", with: "kˈoʊkəɹoʊ")
            .replacingOccurrences(of: "kəkˈɔːɹəʊ", with: "kˈəʊkəɹəʊ")
            .replacingOccurrences(of: "ʲ", with: "j")
            .replacingOccurrences(of: "r", with: "ɹ")
            .replacingOccurrences(of: "x", with: "k")
            .replacingOccurrences(of: "ɬ", with: "l")
            .replacingOccurrences(of: #"(?<=[a-zɹː])(?=hˈʌndɹɪd)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" z(?=[;:,.!?¡¿—…"«»“” ]|$)"#, with: "z", options: .regularExpression)

        if !british {
            phonemes = phonemes.replacingOccurrences(
                of: #"(?<=nˈaɪn)ti(?!ː)"#,
                with: "di",
                options: .regularExpression
            )
        }

        return phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
