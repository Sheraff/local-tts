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
        testDefaultChunkerUsesFirstSentenceForStartup(recorder)
        testDefaultChunkerReachesMinimumForShortFirstSentence(recorder)
        testDefaultChunkerSplitsMediumParagraphAtSentences(recorder)
        testChunkerKeepsInternalPeriodsInsideSentences(recorder)
        try testKokoroFrontendMatchesReferenceGoldens(recorder)
        try testKokoroFrontendPreservesPhonemeTokens(recorder)
        try await testPipelineEmitsFirstChunkBeforeAllChunksAreSynthesized(recorder)
        try await testPipelineWaitsForChunkCallbackBeforeContinuing(recorder)
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
        let text = Array(repeating: paragraph, count: 8).joined(separator: "\n\n")
        let chunks = TextChunker().chunks(from: text)

        recorder.expect(chunks.count > 1, "default chunker splits medium pasted paragraphs")
        recorder.expect(chunks.first?.text.count ?? 0 <= 650, "default chunker keeps first chunk short for faster startup")
        recorder.expect(chunks.allSatisfy { $0.text.count <= 1_200 }, "default chunker respects hard limit")
    }

    @MainActor
    private static func testDefaultChunkerUsesFirstSentenceForStartup(
        _ recorder: FailureRecorder
    ) {
        let firstSentence = """
        This opening sentence is intentionally long enough to clear the startup minimum while still being a single sentence for the first audio chunk.
        """
        let text = """
        \(firstSentence) The second sentence should be left for the following chunk. The third sentence keeps the article long enough to split.
        """
        let chunks = TextChunker().chunks(from: text)

        recorder.expect(chunks.first?.text == firstSentence, "default chunker uses the first full sentence as the startup chunk")
    }

    @MainActor
    private static func testDefaultChunkerReachesMinimumForShortFirstSentence(
        _ recorder: FailureRecorder
    ) {
        let text = """
        Short. This second sentence is long enough to push the first audio chunk over the minimum startup size without exceeding the soft cap. The third sentence should remain outside the first chunk.
        """
        let chunks = TextChunker().chunks(from: text)

        recorder.expect((chunks.first?.text.count ?? 0) >= 100, "default chunker grows a short first sentence to the startup minimum")
        recorder.expect(chunks.first?.text.hasPrefix("Short. This second sentence") == true, "default chunker appends the second sentence when needed")
        recorder.expect(chunks.first?.text.contains("The third sentence") == false, "default chunker stops after reaching the startup minimum")
    }

    @MainActor
    private static func testDefaultChunkerSplitsMediumParagraphAtSentences(
        _ recorder: FailureRecorder
    ) {
        let sentence = """
        This sentence is long enough to build a medium paragraph but short enough to keep a clean sentence boundary.
        """
        let text = Array(repeating: sentence, count: 18).joined(separator: " ")
        let chunks = TextChunker().chunks(from: text)

        recorder.expect(chunks.count > 1, "default chunker splits medium paragraphs at sentence boundaries")
        recorder.expect(chunks.allSatisfy { $0.text.count <= 1_200 }, "sentence chunking respects hard limit")
        recorder.expect(
            chunks.dropLast().allSatisfy { chunk in
                guard let last = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
                    return false
                }
                return ".!?".contains(last)
            },
            "default chunker avoids ending non-final chunks mid-sentence"
        )
    }

    @MainActor
    private static func testChunkerKeepsInternalPeriodsInsideSentences(
        _ recorder: FailureRecorder
    ) {
        let chunker = TextChunker(
            firstMinimumCharacterCount: 1,
            firstHardCharacterLimit: 240,
            targetCharacterCount: 240,
            hardCharacterLimit: 240
        )
        let cases = [
            (
                "In the U.S.A today. We stayed.",
                "In the U.S.A today."
            ),
            (
                "Dr. Smith went home. He slept.",
                "Dr. Smith went home."
            ),
            (
                "This costs 3.14 dollars. We paid.",
                "This costs 3.14 dollars."
            ),
            (
                "Use v1.2.3, not v1.2.2. Then restart.",
                "Use v1.2.3, not v1.2.2."
            ),
            (
                "See example.com. Then continue.",
                "See example.com."
            ),
            (
                "it is a structural problem for U.S. capital. Markets move.",
                "it is a structural problem for U.S. capital."
            ),
        ]

        for (input, expectedFirstChunk) in cases {
            let chunks = chunker.chunks(from: input)
            recorder.expect(
                chunks.first?.text == expectedFirstChunk,
                "chunker keeps internal periods inside one sentence: \(input)"
            )
            recorder.expect(chunks.count == 2, "chunker still splits real sentence boundary: \(input)")
        }
    }

    @MainActor
    private static func testKokoroFrontendMatchesReferenceGoldens(
        _ recorder: FailureRecorder
    ) throws {
        let url = Bundle.module.url(
            forResource: "KokoroFrontendGolden",
            withExtension: "json"
        )
        guard let url else {
            recorder.expect(false, "Kokoro frontend golden fixture is bundled")
            return
        }

        let fixture = try JSONDecoder().decode(
            KokoroFrontendGoldenFixture.self,
            from: Data(contentsOf: url)
        )

        for entry in fixture.cases {
            let actual = try KokoroTextFrontend.phonemes(for: entry.text, british: entry.british)
            recorder.expect(
                actual == entry.phonemes,
                """
                frontend matches \(fixture.source.name) \(fixture.source.version) golden \(entry.id)
                expected: \(entry.phonemes)
                actual:   \(actual)
                """
            )
        }
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
            phonemes.contains("həlˈO"),
            "frontend uses the Kokoro English G2P phonemizer for American English: \(phonemes)"
        )

        let tokenIDs = try KokoroTextFrontend.tokenIDs(for: "Hello world.", tokenizerURL: tokenizerURL)
        let tokenizer = try JSONDecoder().decode(TestTokenizerFile.self, from: Data(contentsOf: tokenizerURL))

        if let kokoroO = tokenizer.model.vocab["O"] {
            recorder.expect(tokenIDs.contains(Int64(kokoroO)), "frontend emits Kokoro O token")
        } else {
            recorder.expect(false, "tokenizer contains Kokoro phoneme vocab entries")
        }

        let currencyPhonemes = try KokoroTextFrontend.phonemes(for: "It costs $12.50.")
        recorder.expect(
            currencyPhonemes.contains("dˈɑləɹz") && currencyPhonemes.contains("sˈɛnts"),
            "frontend expands USD currency into dollars and cents: \(currencyPhonemes)"
        )

        let hyphenatedPhonemes = try KokoroTextFrontend.phonemes(
            for: "A $250-per-month subscription has lock-in and a next-best open-weight option."
        )
        recorder.expect(
            !hyphenatedPhonemes.contains("—"),
            "frontend does not turn intra-word hyphens into pause punctuation: \(hyphenatedPhonemes)"
        )

        let emDashPhonemes = try KokoroTextFrontend.phonemes(for: "Subsidize — train.")
        recorder.expect(
            emDashPhonemes.contains("—"),
            "frontend preserves real em dash pause punctuation: \(emDashPhonemes)"
        )
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
    private static func testPipelineWaitsForChunkCallbackBeforeContinuing(
        _ recorder: FailureRecorder
    ) async throws {
        let gate = BackpressureGate()
        let engine = MockSpeechEngine()
        let pipeline = SpeechSynthesisPipeline(engine: engine)
        let chunks = (0..<5).map { index in
            TextChunk(index: index, text: "Chunk \(index).")
        }
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
                if audio.chunkIndex == 2 {
                    await gate.pauseUntilReleased()
                }
            }
        }

        await gate.waitUntilPaused()
        recorder.expect(await engine.synthesizedCount == 3, "pipeline pauses synthesis while chunk callback applies backpressure")
        recorder.expect(await emitted.values == [0, 1, 2], "pipeline does not emit later chunks while backpressured")
        await gate.release()

        try await task.value
        recorder.expect(await emitted.values == [0, 1, 2, 3, 4], "pipeline resumes after backpressure releases")
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

private struct KokoroFrontendGoldenFixture: Decodable {
    let source: Source
    let cases: [Case]

    struct Source: Decodable {
        let name: String
        let version: String
    }

    struct Case: Decodable {
        let id: String
        let british: Bool
        let text: String
        let phonemes: String
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

private actor BackpressureGate {
    private var paused = false
    private var released = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseUntilReleased() async {
        paused = true
        pauseContinuation?.resume()
        pauseContinuation = nil

        if released {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused {
            return
        }

        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
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
