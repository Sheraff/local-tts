import Foundation

public struct KokoroAssetStatus: Equatable, Sendable {
    public let hasModel: Bool
    public let modelFileName: String?
    public let hasFullPrecisionModel: Bool
    public let hasTokenizer: Bool
    public let voiceCount: Int
    public let expectedEnglishVoiceCount: Int
    public let missingEnglishVoiceCount: Int
    public let modelDirectory: URL

    public var isComplete: Bool {
        hasModel && hasTokenizer && voiceCount > 0
    }

    public var displayText: String {
        if isComplete {
            if missingEnglishVoiceCount > 0 {
                "Kokoro ONNX ready (\(modelFileName ?? "model"), \(voiceCount)/\(expectedEnglishVoiceCount) English voices)"
            } else {
                "Kokoro ONNX ready (\(modelFileName ?? "model"), \(voiceCount) English voices)"
            }
        } else {
            "Kokoro assets missing"
        }
    }
}

public actor KokoroOnnxEngine: SpeechEngine {
    public nonisolated let modelDirectory: URL

    private var engineState: SpeechEngineState = .unloaded
    private var onnxSynthesizer: KokoroOnnxSynthesizer?

    public init(modelDirectory: URL = AppPaths.kokoroModelDirectory) {
        self.modelDirectory = modelDirectory
    }

    public var state: SpeechEngineState {
        engineState
    }

    public func assetStatus() -> KokoroAssetStatus {
        let fullPrecisionModelURL = modelDirectory.appendingPathComponent("onnx/model.onnx")
        let modelCandidates = [
            fullPrecisionModelURL,
            modelDirectory.appendingPathComponent("onnx/model_quantized.onnx"),
        ]
        let modelURL = modelCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
        let hasModel = modelURL != nil
        let hasFullPrecisionModel = FileManager.default.fileExists(atPath: fullPrecisionModelURL.path)
        let hasTokenizer = FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("tokenizer.json").path)
            || FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path)
        let voicesDirectory = modelDirectory.appendingPathComponent("voices", isDirectory: true)
        let voices = (try? FileManager.default.contentsOfDirectory(at: voicesDirectory, includingPropertiesForKeys: nil))
            ?? []
        let installedVoiceIDs = Set(
            voices
                .filter { $0.pathExtension == "bin" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        let installedEnglishVoiceIDs = installedVoiceIDs.intersection(KokoroVoiceCatalog.englishVoiceIDs)
        let voiceCount = installedEnglishVoiceIDs.count
        let expectedEnglishVoiceCount = KokoroVoiceCatalog.englishVoices.count
        let missingEnglishVoiceCount = max(0, expectedEnglishVoiceCount - voiceCount)

        return KokoroAssetStatus(
            hasModel: hasModel,
            modelFileName: modelURL?.lastPathComponent,
            hasFullPrecisionModel: hasFullPrecisionModel,
            hasTokenizer: hasTokenizer,
            voiceCount: voiceCount,
            expectedEnglishVoiceCount: expectedEnglishVoiceCount,
            missingEnglishVoiceCount: missingEnglishVoiceCount,
            modelDirectory: modelDirectory
        )
    }

    public func load() async throws {
        if case .ready = engineState, onnxSynthesizer != nil {
            return
        }

        engineState = .loading
        try AppPaths.ensureRuntimeDirectories()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let status = assetStatus()
        guard status.isComplete else {
            onnxSynthesizer = nil
            engineState = .failed(status.displayText)
            throw SpeechEngineError.missingModelAssets(modelDirectory)
        }

        onnxSynthesizer = try KokoroOnnxSynthesizer(modelDirectory: modelDirectory)
        engineState = .ready
    }

    public func unload() async {
        onnxSynthesizer = nil
        engineState = .unloaded
    }

    public func listVoices() async throws -> [SpeechVoice] {
        let voicesDirectory = modelDirectory.appendingPathComponent("voices", isDirectory: true)
        let installedVoiceIDs = Set(
            ((try? FileManager.default.contentsOfDirectory(at: voicesDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "bin" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )

        if installedVoiceIDs.isEmpty {
            return KokoroVoiceCatalog.englishVoices
        }

        return KokoroVoiceCatalog.englishVoices.filter { installedVoiceIDs.contains($0.id) }
    }

    public func synthesize(
        _ request: SpeechSynthesisRequest,
        outputDirectory: URL
    ) async throws -> SynthesizedAudioChunk {
        if Task.isCancelled {
            throw SpeechEngineError.cancelled
        }

        if onnxSynthesizer == nil {
            try await load()
        }

        engineState = .synthesizing
        defer { engineState = .ready }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent(
            "chunk-\(String(format: "%03d", request.chunkIndex)).wav"
        )

        guard let onnxSynthesizer else {
            engineState = .failed("Kokoro ONNX backend is not loaded")
            throw SpeechEngineError.synthesisFailed("Kokoro ONNX backend is not loaded")
        }
        try onnxSynthesizer.synthesize(request, to: outputURL)

        return SynthesizedAudioChunk(
            requestID: request.id,
            chunkIndex: request.chunkIndex,
            text: request.text,
            fileURL: outputURL,
            estimatedDuration: estimateDuration(for: request.text, speed: request.speed)
        )
    }

    public func cancel() async {
        engineState = .ready
    }

    private func estimateDuration(for text: String, speed: Double) -> TimeInterval {
        let words = max(1, text.split(whereSeparator: \.isWhitespace).count)
        let wordsPerMinute = max(90, 170 * speed)
        return TimeInterval(Double(words) / wordsPerMinute * 60)
    }
}
