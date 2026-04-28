import Foundation

struct KokoroVoiceEmbedding: Sendable {
    private let values: [Float]
    private let rows: Int
    private let columns = 256

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= columns * MemoryLayout<Float>.size,
              data.count.isMultiple(of: columns * MemoryLayout<Float>.size)
        else {
            throw SpeechEngineError.synthesisFailed("Invalid voice embedding file: \(url.lastPathComponent)")
        }

        values = data.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Float.self)
            return Array(buffer)
        }
        rows = values.count / columns
    }

    func styleVector(tokenCount: Int) -> [Float] {
        let row = max(0, min(tokenCount, rows - 1))
        let start = row * columns
        return Array(values[start..<start + columns])
    }
}
