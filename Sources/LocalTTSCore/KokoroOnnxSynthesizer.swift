@preconcurrency import AVFoundation
import Foundation
import OnnxRuntimeBindings

final class KokoroOnnxSynthesizer: @unchecked Sendable {
    private let tokenizer: KokoroTokenizer
    private let env: ORTEnv
    private let session: ORTSession
    private let inputNames: Set<String>
    private let outputNames: Set<String>
    private let modelDirectory: URL

    init(modelDirectory: URL) throws {
        self.modelDirectory = modelDirectory
        tokenizer = try KokoroTokenizer(tokenizerURL: modelDirectory.appendingPathComponent("tokenizer.json"))

        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(0)

        let modelURL = Self.modelURL(in: modelDirectory)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputNames = Set(try session.inputNames())
        outputNames = Set(try session.outputNames())
    }

    func synthesize(_ request: SpeechSynthesisRequest, to outputURL: URL) throws {
        let rawTokenIDs = try tokenizer.tokenIDs(
            for: request.text,
            british: request.voice.id.hasPrefix("b")
        )
        guard !rawTokenIDs.isEmpty else {
            throw SpeechEngineError.synthesisFailed("No Kokoro tokens generated for chunk")
        }

        let leadingContextTokenIDs = tokenizer.leadingContextTokenIDs
        let tokenSegments = segmentedTokenIDs(
            rawTokenIDs,
            maxTokenCount: KokoroTokenizer.maxModelTokenCount - leadingContextTokenIDs.count
        )
        guard !tokenSegments.isEmpty else {
            throw SpeechEngineError.synthesisFailed("No Kokoro token segments generated for chunk")
        }

        let voiceURL = modelDirectory
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent("\(request.voice.id).bin")
        let voiceEmbedding = try KokoroVoiceEmbedding(url: voiceURL)

        var samples: [Float] = []
        for (index, tokenSegment) in tokenSegments.enumerated() {
            try Task.checkCancellation()
            let primedTokenSegment = leadingContextTokenIDs + tokenSegment
            samples.append(
                contentsOf: try synthesizeTokenSegment(
                    primedTokenSegment,
                    voiceEmbedding: voiceEmbedding,
                    speed: request.speed
                )
            )
            if index < (tokenSegments.indices.last ?? 0) {
                samples.append(contentsOf: Array(repeating: 0, count: 1_440))
            }
        }

        try write(samples: samples, to: outputURL)
    }

    private func synthesizeTokenSegment(
        _ rawTokenIDs: [Int64],
        voiceEmbedding: KokoroVoiceEmbedding,
        speed: Double
    ) throws -> [Float] {
        guard rawTokenIDs.count <= KokoroTokenizer.maxModelTokenCount else {
            throw SpeechEngineError.synthesisFailed(
                "Text chunk is too long for Kokoro (\(rawTokenIDs.count) phoneme tokens, max \(KokoroTokenizer.maxModelTokenCount))"
            )
        }

        var tokenIDs = rawTokenIDs
        let styleVector = voiceEmbedding.styleVector(tokenCount: tokenIDs.count)

        tokenIDs.insert(0, at: 0)
        tokenIDs.append(0)

        let inputIDs = try makeInt64Tensor(
            tokenIDs,
            shape: [1, NSNumber(value: tokenIDs.count)]
        )
        let style = try makeFloatTensor(
            styleVector,
            shape: [1, NSNumber(value: styleVector.count)]
        )
        let speed = try makeFloatTensor(
            [Float(speed)],
            shape: [1]
        )

        let inputs = [
            inputName(preferred: "input_ids"): inputIDs,
            inputName(preferred: "style"): style,
            inputName(preferred: "speed"): speed,
        ]

        let outputs = try session.run(
            withInputs: inputs,
            outputNames: outputNames,
            runOptions: nil
        )

        guard let firstOutput = outputs[outputNames.sorted().first ?? ""] ?? outputs.values.first else {
            throw SpeechEngineError.synthesisFailed("Kokoro produced no audio output")
        }

        let audioData = try firstOutput.tensorData()
        let sampleCount = audioData.length / MemoryLayout<Float>.stride
        return Array(
            UnsafeBufferPointer(
                start: audioData.bytes.assumingMemoryBound(to: Float.self),
                count: sampleCount
            )
        )
    }

    private func segmentedTokenIDs(
        _ tokenIDs: [Int64],
        maxTokenCount: Int = KokoroTokenizer.maxModelTokenCount
    ) -> [[Int64]] {
        guard tokenIDs.count > maxTokenCount else {
            return [tokenIDs]
        }

        let breakTokenIDs = tokenizer.preferredBreakTokenIDs
        var segments: [[Int64]] = []
        var start = 0

        while start < tokenIDs.count {
            let limit = min(start + maxTokenCount, tokenIDs.count)
            if limit == tokenIDs.count {
                segments.append(Array(tokenIDs[start..<limit]))
                break
            }

            let searchStart = max(start, limit - 160)
            var end = limit
            if !breakTokenIDs.isEmpty {
                for index in stride(from: limit - 1, through: searchStart, by: -1) where breakTokenIDs.contains(tokenIDs[index]) {
                    end = index + 1
                    break
                }
            }

            if end <= start {
                end = limit
            }

            segments.append(Array(tokenIDs[start..<end]))
            start = end
        }

        return segments
    }

    private func inputName(preferred: String) -> String {
        inputNames.contains(preferred) ? preferred : preferred
    }

    private func makeInt64Tensor(
        _ values: [Int64],
        shape: [NSNumber]
    ) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { buffer in
            NSMutableData(
                bytes: buffer.baseAddress,
                length: values.count * MemoryLayout<Int64>.stride
            )
        }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
    }

    private func makeFloatTensor(
        _ values: [Float],
        shape: [NSNumber]
    ) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { buffer in
            NSMutableData(
                bytes: buffer.baseAddress,
                length: values.count * MemoryLayout<Float>.stride
            )
        }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    private func write(samples: [Float], to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechEngineError.synthesisFailed("Could not create audio format")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw SpeechEngineError.synthesisFailed("Could not allocate audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError.synthesisFailed("Could not write audio samples")
        }
        channel.update(from: samples, count: samples.count)

        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func modelURL(in modelDirectory: URL) -> URL {
        let candidates = [
            "onnx/model.onnx",
            "onnx/model_quantized.onnx",
            "onnx/model_q8f16.onnx",
        ]
        for candidate in candidates {
            let url = modelDirectory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return modelDirectory.appendingPathComponent("onnx/model_q8f16.onnx")
    }
}
