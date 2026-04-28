@preconcurrency import AVFoundation
import Foundation
import LocalTTSCore

@main
struct LocalTTSTestRunner {
    @MainActor
    static func main() async throws {
        let recorder = FailureRecorder()

        testNormalizeRemovesObviousChromeAndPreservesParagraphs(recorder)
        testChunkerKeepsChunksUnderHardLimitForLongParagraphs(recorder)
        testDefaultChunkerSplitsMediumPastedParagraphs(recorder)
        testDefaultChunkerSplitsMediumParagraphAtSentences(recorder)
        try testKokoroFrontendPreservesPhonemeTokens(recorder)
        try await testPipelineEmitsFirstChunkBeforeAllChunksAreSynthesized(recorder)
        try await testKokoroOnnxSynthesizesWhenAssetsExist(recorder)
        try await testKokoroVoicesProduceDifferentAudio(recorder)

        if recorder.failures.isEmpty {
            print("All LocalTTS tests passed")
        } else {
            for failure in recorder.failures {
                print("FAIL: \(failure)")
            }
            throw TestFailure()
        }
    }

    @MainActor
    private static func testNormalizeRemovesObviousChromeAndPreservesParagraphs(
        _ recorder: FailureRecorder
    ) {
        let input = """
        Home

        This is the first paragraph.   It has extra spacing.

        Advertisement

        This is the second paragraph.

        Privacy Policy
        """

        let normalized = TextNormalizer().normalize(input)

        recorder.expect(!normalized.localizedCaseInsensitiveContains("advertisement"), "normalizer removes advertisement")
        recorder.expect(!normalized.localizedCaseInsensitiveContains("privacy policy"), "normalizer removes privacy policy")
        recorder.expect(normalized.contains("first paragraph. It has extra spacing."), "normalizer collapses inline whitespace")
        recorder.expect(normalized.contains("\n\nThis is the second paragraph."), "normalizer preserves paragraph boundary")
    }

    @MainActor
    private static func testChunkerKeepsChunksUnderHardLimitForLongParagraphs(
        _ recorder: FailureRecorder
    ) {
        let sentence = "This is a sentence with enough words to be useful for testing chunk boundaries."
        let text = Array(repeating: sentence, count: 80).joined(separator: " ")
        let chunker = TextChunker(targetCharacterCount: 500, hardCharacterLimit: 700)
        let chunks = chunker.chunks(from: text)

        recorder.expect(chunks.count > 1, "chunker splits long text")
        recorder.expect(chunks.allSatisfy { $0.text.count <= 700 }, "chunker respects hard limit")
        recorder.expect(chunks.map(\.index) == Array(0..<chunks.count), "chunker assigns sequential indexes")
    }

    @MainActor
    private static func testDefaultChunkerSplitsMediumPastedParagraphs(
        _ recorder: FailureRecorder
    ) {
        let paragraph = """
        This is a realistic pasted paragraph with enough ordinary article text to matter. It should not wait \
        for multiple paragraphs to be synthesized before playback begins, because quick first audio matters \
        more than creating very large chunks for the local model.
        """
        let text = Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
        let chunks = TextChunker().chunks(from: text)

        recorder.expect(chunks.count > 1, "default chunker splits medium pasted paragraphs")
        recorder.expect(chunks.first?.text.count ?? 0 <= 650, "default chunker keeps first chunk bounded")
        recorder.expect(chunks.allSatisfy { $0.text.count <= 650 }, "default chunker respects hard limit")
    }

    @MainActor
    private static func testDefaultChunkerSplitsMediumParagraphAtSentences(
        _ recorder: FailureRecorder
    ) {
        let sentence = """
        This sentence is long enough to build a medium paragraph but short enough to keep a clean sentence boundary.
        """
        let text = Array(repeating: sentence, count: 8).joined(separator: " ")
        let chunks = TextChunker().chunks(from: text)

        recorder.expect(chunks.count > 1, "default chunker splits medium paragraphs at sentence boundaries")
        recorder.expect(chunks.allSatisfy { $0.text.count <= 650 }, "sentence chunking respects hard limit")
    }

    @MainActor
    private static func testKokoroFrontendPreservesPhonemeTokens(
        _ recorder: FailureRecorder
    ) throws {
        let tokenizerURL = AppPaths.kokoroModelDirectory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            print("Skipping Kokoro frontend token test; tokenizer is not installed")
            return
        }

        let phonemes = try KokoroTextFrontend.phonemes(for: "Hello world.")
        recorder.expect(
            phonemes.contains("həlˈoʊ"),
            "frontend uses the reference eSpeak phonemizer for American English: \(phonemes)"
        )

        let tokenIDs = try KokoroTextFrontend.tokenIDs(for: "Hello world.", tokenizerURL: tokenizerURL)
        let tokenizer = try JSONDecoder().decode(TestTokenizerFile.self, from: Data(contentsOf: tokenizerURL))

        if let lowerO = tokenizer.model.vocab["o"], let upsilon = tokenizer.model.vocab["ʊ"] {
            recorder.expect(tokenIDs.contains(Int64(lowerO)), "frontend emits eSpeak o token")
            recorder.expect(tokenIDs.contains(Int64(upsilon)), "frontend emits eSpeak upsilon token")
        } else {
            recorder.expect(false, "tokenizer contains eSpeak phoneme vocab entries")
        }
    }

    @MainActor
    private static func testPipelineEmitsFirstChunkBeforeAllChunksAreSynthesized(
        _ recorder: FailureRecorder
    ) async throws {
        let gate = SynthesisGate()
        let engine = MockSpeechEngine(gate: gate)
        let pipeline = SpeechSynthesisPipeline(engine: engine)
        let chunks = [
            TextChunk(index: 0, text: "First chunk."),
            TextChunk(index: 1, text: "Second chunk."),
            TextChunk(index: 2, text: "Third chunk."),
        ]
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let emitted = EmissionRecorder()
        let task = Task {
            try await pipeline.synthesize(
                chunks: chunks,
                voice: SpeechVoice(id: "af_heart", name: "Heart", language: "English", detail: "Test"),
                speed: 1,
                outputDirectory: outputDirectory
            ) { audio in
                await emitted.append(audio.chunkIndex)
            }
        }

        await gate.waitUntilSecondChunkRequested()
        let synthesizedCount = await engine.synthesizedCount
        let emittedValues = await emitted.values
        recorder.expect(
            synthesizedCount == 1 && emittedValues == [0],
            "pipeline emits first chunk before later chunks finish"
        )
        await gate.releaseSecondChunk()

        try await task.value
        recorder.expect(await emitted.values == [0, 1, 2], "pipeline emits chunks in order")
    }

    @MainActor
    private static func testKokoroOnnxSynthesizesWhenAssetsExist(
        _ recorder: FailureRecorder
    ) async throws {
        let engine = KokoroOnnxEngine()
        let status = await engine.assetStatus()
        guard status.isComplete else {
            print("Skipping Kokoro ONNX smoke test; assets are not installed")
            return
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let voice = SpeechVoice(id: "af_heart", name: "Heart", language: "English US", detail: "Test")
        let audio = try await engine.synthesize(
            SpeechSynthesisRequest(
                text: "Hello from local Kokoro.",
                voice: voice,
                speed: 1,
                chunkIndex: 0,
                totalChunks: 1
            ),
            outputDirectory: outputDirectory
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: audio.fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        recorder.expect(fileSize > 44, "Kokoro ONNX writes non-empty audio")

        let audioFile = try AVAudioFile(forReading: audio.fileURL)
        recorder.expect(
            Int(audioFile.fileFormat.sampleRate.rounded()) == 24_000,
            "Kokoro ONNX writes 24 kHz model audio"
        )
        recorder.expect(audioFile.length > 1_000, "Kokoro ONNX writes audible samples")
        await engine.unload()
    }

    @MainActor
    private static func testKokoroVoicesProduceDifferentAudio(
        _ recorder: FailureRecorder
    ) async throws {
        let engine = KokoroOnnxEngine()
        let status = await engine.assetStatus()
        guard status.isComplete else {
            print("Skipping Kokoro voice-conditioning test; assets are not installed")
            return
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let text = "The voice selector should change the speaker clearly."
        let heart = try await synthesizeSamples(
            engine: engine,
            voiceID: "af_heart",
            name: "Heart",
            text: text,
            outputDirectory: outputDirectory,
            chunkIndex: 0
        )
        let adam = try await synthesizeSamples(
            engine: engine,
            voiceID: "am_adam",
            name: "Adam",
            text: text,
            outputDirectory: outputDirectory,
            chunkIndex: 1
        )
        let emma = try await synthesizeSamples(
            engine: engine,
            voiceID: "bf_emma",
            name: "Emma",
            text: text,
            outputDirectory: outputDirectory,
            chunkIndex: 2
        )
        let george = try await synthesizeSamples(
            engine: engine,
            voiceID: "bm_george",
            name: "George",
            text: text,
            outputDirectory: outputDirectory,
            chunkIndex: 3
        )

        recorder.expect(meanAbsoluteDifference(heart, adam) > 0.005, "American female and male voices produce different audio")
        recorder.expect(meanAbsoluteDifference(emma, george) > 0.005, "British female and male voices produce different audio")
        recorder.expect(meanAbsoluteDifference(heart, emma) > 0.005, "American and British female voices produce different audio")
        await engine.unload()
    }

    private static func synthesizeSamples(
        engine: KokoroOnnxEngine,
        voiceID: String,
        name: String,
        text: String,
        outputDirectory: URL,
        chunkIndex: Int
    ) async throws -> [Float] {
        let audio = try await engine.synthesize(
            SpeechSynthesisRequest(
                text: text,
                voice: SpeechVoice(id: voiceID, name: name, language: "English", detail: "Test"),
                speed: 1,
                chunkIndex: chunkIndex,
                totalChunks: 4
            ),
            outputDirectory: outputDirectory
        )
        return try readFloatSamples(from: audio.fileURL)
    }

    private static func readFloatSamples(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        ) else {
            return []
        }
        try audioFile.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func meanAbsoluteDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else {
            return 0
        }
        var total: Float = 0
        for index in 0..<count {
            total += abs(lhs[index] - rhs[index])
        }
        return total / Float(count)
    }
}

@MainActor
private final class FailureRecorder {
    private(set) var failures: [String] = []

    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures.append(message)
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }
}

private struct TestFailure: Error {}

private struct TestTokenizerFile: Decodable {
    let model: Model

    struct Model: Decodable {
        let vocab: [String: Int]
    }
}

private actor EmissionRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private actor SynthesisGate {
    private var secondChunkRequested = false
    private var secondChunkReleased = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markSecondChunkRequested() {
        secondChunkRequested = true
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func waitUntilSecondChunkRequested() async {
        if secondChunkRequested {
            return
        }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func releaseSecondChunk() {
        secondChunkReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitForSecondChunkRelease() async {
        if secondChunkReleased {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

private actor MockSpeechEngine: SpeechEngine {
    let modelDirectory = URL(fileURLWithPath: "/tmp/mock")
    private let gate: SynthesisGate?
    private var engineState: SpeechEngineState = .unloaded
    private(set) var synthesizedCount = 0

    init(gate: SynthesisGate? = nil) {
        self.gate = gate
    }

    var state: SpeechEngineState {
        engineState
    }

    func load() async throws {
        engineState = .ready
    }

    func unload() async {
        engineState = .unloaded
    }

    func listVoices() async throws -> [SpeechVoice] {
        [SpeechVoice(id: "mock", name: "Mock", language: "English", detail: "Test")]
    }

    func synthesize(
        _ request: SpeechSynthesisRequest,
        outputDirectory: URL
    ) async throws -> SynthesizedAudioChunk {
        if request.chunkIndex == 1 {
            await gate?.markSecondChunkRequested()
            await gate?.waitForSecondChunkRelease()
        }
        synthesizedCount += 1
        let fileURL = outputDirectory.appendingPathComponent("mock-\(request.chunkIndex).aiff")
        try Data().write(to: fileURL)
        return SynthesizedAudioChunk(
            requestID: request.id,
            chunkIndex: request.chunkIndex,
            text: request.text,
            fileURL: fileURL,
            estimatedDuration: 1
        )
    }

    func cancel() async {}
}
