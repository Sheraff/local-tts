@preconcurrency import AVFoundation
import Foundation
import LocalTTSCore

enum LocalTTSDiagnostics {
    static func runAndExit() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let exitCode = ExitCodeBox()

        Task.detached {
            exitCode.value = await run()
            semaphore.signal()
        }

        semaphore.wait()
        Foundation.exit(exitCode.value)
    }

    private static func run() async -> Int32 {
        print("Local TTS diagnostics")
        print("Bundle: \(Bundle.main.bundleURL.path)")
        print("Executable: \(Bundle.main.executableURL?.path ?? "Unknown")")
        print("Bundle identifier: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        print("Application Support: \(AppPaths.applicationSupportDirectory.path)")
        print("Kokoro model: \(AppPaths.kokoroModelDirectory.path)")

        let engine = KokoroOnnxEngine()
        let status = await engine.assetStatus()
        print("Model status: \(status.displayText)")
        print("Model file: \(status.hasModel ? "yes" : "no")")
        print("Tokenizer: \(status.hasTokenizer ? "yes" : "no")")
        print("Voice files: \(status.voiceCount)")

        let frontend = KokoroTextFrontend.diagnostics()
        print("Frontend: \(frontend.displayText)")
        print("Phonemizer backend: \(frontend.backend)")
        print("eSpeak data: \(frontend.dataPath)")
        if let americanSample = frontend.americanSample {
            print("US sample: \(americanSample)")
        }
        if let britishSample = frontend.britishSample {
            print("UK sample: \(britishSample)")
        }

        do {
            let voices = try await engine.listVoices()
            print("Voices: \(voices.map(\.id).joined(separator: ", "))")
        } catch {
            print("Voices: failed: \(error.localizedDescription)")
            return 1
        }

        if CommandLine.arguments.contains("--write-samples") {
            do {
                try await writeSamples(engine: engine)
            } catch {
                print("Sample synthesis: failed: \(error.localizedDescription)")
                return 1
            }
        }

        return status.isComplete && frontend.isReady ? 0 : 1
    }

    private static func writeSamples(engine: KokoroOnnxEngine) async throws {
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LocalTTS-Diagnostics", isDirectory: true)
        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let text = "The voice selector should produce a clearly different speaker."
        let voices = [
            SpeechVoice(id: "af_heart", name: "Heart", language: "English US", detail: "American female"),
            SpeechVoice(id: "am_adam", name: "Adam", language: "English US", detail: "American male"),
            SpeechVoice(id: "bf_emma", name: "Emma", language: "English UK", detail: "British female"),
            SpeechVoice(id: "bm_george", name: "George", language: "English UK", detail: "British male"),
        ]

        print("Writing samples: \(outputDirectory.path)")
        var samplesByVoice: [(String, [Float])] = []
        for (index, voice) in voices.enumerated() {
            let audio = try await engine.synthesize(
                SpeechSynthesisRequest(
                    text: text,
                    voice: voice,
                    speed: 1,
                    chunkIndex: index,
                    totalChunks: voices.count
                ),
                outputDirectory: outputDirectory
            )
            let samples = try readSamples(from: audio.fileURL)
            samplesByVoice.append((voice.id, samples))
            print("Sample \(voice.id): \(audio.fileURL.path) (\(samples.count) samples)")
        }

        for lhsIndex in 0..<samplesByVoice.count {
            for rhsIndex in (lhsIndex + 1)..<samplesByVoice.count {
                let lhs = samplesByVoice[lhsIndex]
                let rhs = samplesByVoice[rhsIndex]
                print("Mean absolute difference \(lhs.0) vs \(rhs.0): \(meanAbsoluteDifference(lhs.1, rhs.1))")
            }
        }

        await engine.unload()
    }

    private static func readSamples(from url: URL) throws -> [Float] {
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

private final class ExitCodeBox: @unchecked Sendable {
    var value: Int32 = 1
}
