import Foundation

public enum SpeechEngineState: Equatable, Sendable {
    case unloaded
    case loading
    case ready
    case synthesizing
    case failed(String)

    public var displayText: String {
        switch self {
        case .unloaded:
            "Unloaded"
        case .loading:
            "Loading"
        case .ready:
            "Loaded"
        case .synthesizing:
            "Synthesizing"
        case let .failed(message):
            "Failed: \(message)"
        }
    }
}

public enum SpeechEngineError: LocalizedError, Equatable {
    case missingModelAssets(URL)
    case noVoices
    case cancelled
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingModelAssets(url):
            "Missing model assets at \(url.path)"
        case .noVoices:
            "No voices are available"
        case .cancelled:
            "Synthesis was cancelled"
        case let .synthesisFailed(message):
            "Synthesis failed: \(message)"
        }
    }
}

public protocol SpeechEngine: AnyObject, Sendable {
    var state: SpeechEngineState { get async }
    var modelDirectory: URL { get async }

    func load() async throws
    func unload() async
    func listVoices() async throws -> [SpeechVoice]
    func synthesize(_ request: SpeechSynthesisRequest, outputDirectory: URL) async throws -> SynthesizedAudioChunk
    func cancel() async
}

public final class SpeechSynthesisPipeline: Sendable {
    private let engine: any SpeechEngine

    public init(engine: any SpeechEngine) {
        self.engine = engine
    }

    public func synthesize(
        chunks: [TextChunk],
        voice: SpeechVoice,
        speed: Double,
        outputDirectory: URL,
        onChunk: @MainActor @Sendable (SynthesizedAudioChunk) async throws -> Void
    ) async throws {
        try await engine.load()

        for chunk in chunks {
            try Task.checkCancellation()
            let request = SpeechSynthesisRequest(
                text: chunk.text,
                voice: voice,
                speed: speed,
                chunkIndex: chunk.index,
                totalChunks: chunks.count
            )
            let audio = try await engine.synthesize(request, outputDirectory: outputDirectory)
            try await onChunk(audio)
        }
    }
}
