import Foundation

final class KokoroTokenizer: @unchecked Sendable {
    static let maxModelTokenCount = 510

    private let vocabulary: [String: Int64]
    private let allowedCharacters: Set<Character>
    private let phonemizer = KokoroPhonemizer()

    init(tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL)
        let tokenizer = try JSONDecoder().decode(KokoroTokenizerFile.self, from: data)
        vocabulary = tokenizer.model.vocab.mapValues { Int64($0) }
        allowedCharacters = Set(vocabulary.keys.compactMap { $0.count == 1 ? $0.first : nil })
    }

    var sentenceBreakTokenIDs: Set<Int64> {
        Set([".", "!", "?", ";", ":"].compactMap { vocabulary[$0] })
    }

    var softBreakTokenIDs: Set<Int64> {
        Set([",", " "].compactMap { vocabulary[$0] })
    }

    func tokenize(_ text: String, british: Bool, maxTokenCount: Int = KokoroTokenizer.maxModelTokenCount) throws -> [Int64] {
        let tokenIDs = try tokenIDs(for: text, british: british)
        guard tokenIDs.count <= maxTokenCount else {
            throw SpeechEngineError.synthesisFailed(
                "Text chunk is too long for Kokoro (\(tokenIDs.count) phoneme tokens, max \(maxTokenCount))"
            )
        }
        return tokenIDs
    }

    func tokenIDs(for text: String, british: Bool) throws -> [Int64] {
        let phonemes = try phonemize(text, british: british)
        return normalize(phonemes).compactMap { character -> Int64? in
            vocabulary[String(character)]
        }
    }

    private func phonemize(_ text: String, british: Bool) throws -> String {
        try phonemizer.phonemize(text, british: british)
    }

    private func normalize(_ text: String) -> String {
        var result = ""
        var previousWasWhitespace = false

        for character in text.precomposedStringWithCompatibilityMapping {
            if character.isWhitespace {
                if !previousWasWhitespace, !result.isEmpty {
                    result.append(" ")
                    previousWasWhitespace = true
                }
                continue
            }

            if allowedCharacters.contains(character) {
                result.append(character)
                previousWasWhitespace = false
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum KokoroTextFrontend {
    public static func phonemes(for text: String, british: Bool = false) throws -> String {
        try KokoroPhonemizer().phonemize(text, british: british)
    }

    public static func tokenIDs(
        for text: String,
        tokenizerURL: URL,
        british: Bool = false
    ) throws -> [Int64] {
        try KokoroTokenizer(tokenizerURL: tokenizerURL).tokenize(text, british: british)
    }

    public static func diagnostics(sampleText: String = "Hello world.") -> KokoroFrontendDiagnostics {
        do {
            let americanPhonemes = try KokoroPhonemizer().phonemize(sampleText, british: false)
            let britishPhonemes = try KokoroPhonemizer().phonemize(sampleText, british: true)
            return KokoroFrontendDiagnostics(
                backend: KokoroPhonemizer.backendDescription,
                dataPath: KokoroPhonemizer.dataRootURL.path,
                americanSample: americanPhonemes,
                britishSample: britishPhonemes,
                error: nil
            )
        } catch {
            return KokoroFrontendDiagnostics(
                backend: KokoroPhonemizer.backendDescription,
                dataPath: KokoroPhonemizer.dataRootURL.path,
                americanSample: nil,
                britishSample: nil,
                error: error.localizedDescription
            )
        }
    }
}

public struct KokoroFrontendDiagnostics: Equatable, Sendable {
    public let backend: String
    public let dataPath: String
    public let americanSample: String?
    public let britishSample: String?
    public let error: String?

    public var isReady: Bool {
        error == nil && americanSample != nil && britishSample != nil
    }

    public var displayText: String {
        if let error {
            return "Phonemizer failed: \(error)"
        }
        return "\(backend) ready"
    }
}

private struct KokoroTokenizerFile: Decodable {
    let model: Model

    struct Model: Decodable {
        let vocab: [String: Int]
    }
}
