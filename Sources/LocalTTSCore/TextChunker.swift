import Foundation
import NaturalLanguage

public struct TextChunker: Sendable {
    public let firstMinimumCharacterCount: Int
    public let firstHardCharacterLimit: Int
    public let targetCharacterCount: Int
    public let hardCharacterLimit: Int

    public init(
        firstMinimumCharacterCount: Int = 100,
        firstHardCharacterLimit: Int = 650,
        targetCharacterCount: Int = 900,
        hardCharacterLimit: Int = 1_200
    ) {
        self.firstMinimumCharacterCount = firstMinimumCharacterCount
        self.firstHardCharacterLimit = firstHardCharacterLimit
        self.targetCharacterCount = targetCharacterCount
        self.hardCharacterLimit = hardCharacterLimit
    }

    public func chunks(from text: String) -> [TextChunk] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var rawChunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let units = splitParagraph(paragraph)

            for (unitIndex, unit) in units.enumerated() {
                if current.isEmpty {
                    current = unit
                    continue
                }

                let separator = unitIndex == 0 ? "\n\n" : " "
                let candidate = current + separator + unit

                if shouldMerge(current: current, candidate: candidate, isFirstChunk: rawChunks.isEmpty) {
                    current = candidate
                } else {
                    rawChunks.append(current)
                    current = unit
                }
            }
        }

        if !current.isEmpty {
            rawChunks.append(current)
        }

        return rawChunks.enumerated().map { index, text in
            TextChunk(index: index, text: text)
        }
    }

    private func shouldMerge(current: String, candidate: String, isFirstChunk: Bool) -> Bool {
        if isFirstChunk {
            return current.count < firstMinimumCharacterCount && candidate.count <= firstHardCharacterLimit
        }

        return candidate.count <= targetCharacterCount
            || (current.count < targetCharacterCount / 2 && candidate.count <= hardCharacterLimit)
    }

    private func splitParagraph(_ paragraph: String) -> [String] {
        let sentences = splitSentences(paragraph)
        var units: [String] = []

        for sentence in sentences {
            if sentence.count > hardCharacterLimit {
                units.append(contentsOf: splitByWords(sentence))
            } else {
                units.append(sentence)
            }
        }

        return units
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        return sentences.isEmpty ? [text] : sentences
    }

    private func splitByWords(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let word = String(word)
            if word.count > hardCharacterLimit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitLongWord(word))
            } else if current.isEmpty {
                current = word
            } else if (current + " " + word).count <= hardCharacterLimit {
                current += " " + word
            } else {
                chunks.append(current)
                current = word
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func splitLongWord(_ word: String) -> [String] {
        var chunks: [String] = []
        var current = ""

        for character in word {
            current.append(character)
            if current.count >= hardCharacterLimit {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }
}
