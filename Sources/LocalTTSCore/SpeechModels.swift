import Foundation

public struct SpeechVoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let detail: String

    public init(id: String, name: String, language: String, detail: String) {
        self.id = id
        self.name = name
        self.language = language
        self.detail = detail
    }
}

public struct TextChunk: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let text: String

    public init(id: UUID = UUID(), index: Int, text: String) {
        self.id = id
        self.index = index
        self.text = text
    }
}

public struct SpeechSynthesisRequest: Sendable {
    public let id: UUID
    public let text: String
    public let voice: SpeechVoice
    public let speed: Double
    public let chunkIndex: Int
    public let totalChunks: Int

    public init(
        id: UUID = UUID(),
        text: String,
        voice: SpeechVoice,
        speed: Double,
        chunkIndex: Int,
        totalChunks: Int
    ) {
        self.id = id
        self.text = text
        self.voice = voice
        self.speed = speed
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
    }
}

public struct SynthesizedAudioChunk: Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let chunkIndex: Int
    public let text: String
    public let fileURL: URL
    public let estimatedDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        chunkIndex: Int,
        text: String,
        fileURL: URL,
        estimatedDuration: TimeInterval
    ) {
        self.id = id
        self.requestID = requestID
        self.chunkIndex = chunkIndex
        self.text = text
        self.fileURL = fileURL
        self.estimatedDuration = estimatedDuration
    }
}

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case completed
    case failed(String)

    public var displayText: String {
        switch self {
        case .idle:
            "Idle"
        case .preparing:
            "Preparing"
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .completed:
            "Complete"
        case let .failed(message):
            "Failed: \(message)"
        }
    }
}
