import Foundation

public struct TextChunker: Sendable {
    public let targetCharacterCount: Int
    public let hardCharacterLimit: Int

    public init(targetCharacterCount: Int = 420, hardCharacterLimit: Int = 650) {
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

                if candidate.count <= targetCharacterCount
                    || (current.count < targetCharacterCount / 2 && candidate.count <= hardCharacterLimit)
                {
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

    private func splitParagraph(_ paragraph: String) -> [String] {
        if paragraph.count <= targetCharacterCount {
            return [paragraph]
        }

        let sentences = splitSentences(paragraph)
        var units: [String] = []
        var current = ""

        for sentence in sentences {
            if sentence.count > hardCharacterLimit {
                if !current.isEmpty {
                    units.append(current)
                    current = ""
                }
                units.append(contentsOf: splitByWords(sentence))
                continue
            }

            if current.isEmpty {
                current = sentence
            } else if (current + " " + sentence).count <= targetCharacterCount {
                current += " " + sentence
            } else {
                units.append(current)
                current = sentence
            }
        }

        if !current.isEmpty {
            units.append(current)
        }

        return units
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if ".!?".unicodeScalars.contains(scalar) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }

        return sentences
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
