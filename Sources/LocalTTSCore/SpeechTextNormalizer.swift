import Foundation

public protocol SpeechTextNormalizer: Sendable {
    var displayName: String { get }

    func normalize(_ input: String) async throws -> String
}

public struct BasicSpeechTextNormalizer: SpeechTextNormalizer {
    private let normalizer: TextNormalizer

    public var displayName: String {
        "Built-in cleanup"
    }

    public init(normalizer: TextNormalizer = TextNormalizer()) {
        self.normalizer = normalizer
    }

    public func normalize(_ input: String) async throws -> String {
        normalizer.normalize(input)
    }
}

public struct TextNormalizationPipeline: SpeechTextNormalizer {
    private let stages: [any SpeechTextNormalizer]

    public var displayName: String {
        stages.map(\.displayName).joined(separator: " + ")
    }

    public init(stages: [any SpeechTextNormalizer]) {
        self.stages = stages
    }

    public static func appDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TextNormalizationPipeline {
        var stages: [any SpeechTextNormalizer] = [
            BasicSpeechTextNormalizer(),
        ]

        if let command = environment["LOCAL_TTS_TEXT_NORMALIZER_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            stages.append(
                ExternalProcessTextNormalizer(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-lc", command],
                    displayName: "External TN",
                    timeout: 30
                )
            )
        } else if let runtimeDirectory = environment["LOCAL_TTS_SPARROWHAWK_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !runtimeDirectory.isEmpty,
                  let normalizer = SparrowhawkTextNormalizer(runtimeDirectory: URL(fileURLWithPath: runtimeDirectory)) {
            stages.append(normalizer)
        } else if let normalizer = SparrowhawkTextNormalizer.bundled() {
            stages.append(normalizer)
        }

        return TextNormalizationPipeline(stages: stages)
    }

    public func normalize(_ input: String) async throws -> String {
        var output = input
        for stage in stages {
            output = try await stage.normalize(output)
        }
        return output
    }
}

public struct ExternalProcessTextNormalizer: SpeechTextNormalizer {
    public let executableURL: URL
    public let arguments: [String]
    public let displayName: String
    public let timeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String] = [],
        displayName: String,
        timeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.displayName = displayName
        self.timeout = timeout
    }

    public func normalize(_ input: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runProcess(input: input)
        }.value
    }

    private func runProcess(input: String) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = LockedDataBuffer()
        let errorOutput = LockedDataBuffer()
        let termination = DispatchSemaphore(value: 0)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                output.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorOutput.append(data)
            }
        }

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw TextNormalizationError.commandFailed(error.localizedDescription)
        }

        if let data = input.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()

        let result = termination.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw TextNormalizationError.timedOut(timeout)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let message = errorOutput.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw TextNormalizationError.commandExited(process.terminationStatus, message)
        }

        let normalized = output.string().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw TextNormalizationError.emptyOutput
        }

        return normalized
    }
}

public struct SparrowhawkTextNormalizer: SpeechTextNormalizer {
    public let executableURL: URL
    public let resourceDirectory: URL

    public var displayName: String {
        "Native NeMo/Sparrowhawk TN"
    }

    public init?(runtimeDirectory: URL) {
        self.init(
            executableURL: runtimeDirectory
                .appendingPathComponent("bin")
                .appendingPathComponent("nemo_normalizer_main"),
            resourceDirectory: runtimeDirectory.appendingPathComponent("share")
        )
    }

    public init?(executableURL: URL, resourceDirectory: URL) {
        let requiredResources = [
            resourceDirectory.appendingPathComponent("tokenizer.ascii_proto"),
            resourceDirectory.appendingPathComponent("verbalizer_final.ascii_proto"),
            resourceDirectory
                .appendingPathComponent("classify")
                .appendingPathComponent("tokenize_and_classify.far"),
            resourceDirectory
                .appendingPathComponent("verbalize")
                .appendingPathComponent("verbalize_final.far"),
        ]
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              requiredResources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        self.executableURL = executableURL
        self.resourceDirectory = resourceDirectory
    }

    public static func bundled(bundle: Bundle = .main) -> SparrowhawkTextNormalizer? {
        for candidate in bundledCandidates(bundle: bundle) {
            if let normalizer = SparrowhawkTextNormalizer(
                executableURL: candidate.executableURL,
                resourceDirectory: candidate.resourceDirectory
            ) {
                return normalizer
            }
        }
        return nil
    }

    public func normalize(_ input: String) async throws -> String {
        try await ExternalProcessTextNormalizer(
            executableURL: executableURL,
            arguments: [
                "--path_prefix=\(resourceDirectory.path)",
            ],
            displayName: displayName,
            timeout: 60
        )
        .normalize(input)
    }

    private static func bundledCandidates(bundle: Bundle) -> [(executableURL: URL, resourceDirectory: URL)] {
        var candidates: [(URL, URL)] = []

        if let executableURL = bundle.executableURL {
            let macOSDirectory = executableURL.deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            candidates.append((
                macOSDirectory.appendingPathComponent("LocalTTSNemoNormalizer"),
                contentsDirectory
                    .appendingPathComponent("Resources")
                    .appendingPathComponent("Sparrowhawk")
            ))
        }

        if let resourceURL = bundle.resourceURL,
           let executableURL = bundle.executableURL {
            candidates.append((
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("LocalTTSNemoNormalizer"),
                resourceURL.appendingPathComponent("Sparrowhawk")
            ))
        }

        return candidates
    }
}

public enum TextNormalizationError: LocalizedError, Equatable {
    case commandFailed(String)
    case commandExited(Int32, String)
    case timedOut(TimeInterval)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            "Text normalizer failed to start: \(message)"
        case let .commandExited(status, message):
            if message.isEmpty {
                "Text normalizer exited with status \(status)"
            } else {
                "Text normalizer exited with status \(status): \(message)"
            }
        case let .timedOut(seconds):
            "Text normalizer timed out after \(Int(seconds)) seconds"
        case .emptyOutput:
            "Text normalizer produced no output"
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let current = data
        lock.unlock()
        return String(data: current, encoding: .utf8) ?? ""
    }
}
