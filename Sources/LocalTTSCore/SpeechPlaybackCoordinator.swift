import AVFoundation
import Foundation

@MainActor
public final class SpeechPlaybackCoordinator: NSObject, ObservableObject {
    @Published public private(set) var status: PlaybackStatus = .idle
    @Published public private(set) var currentChunkIndex = 0
    @Published public private(set) var totalChunks = 0
    @Published public private(set) var queuedChunks = 0
    @Published public private(set) var captureSource: CaptureSource = .none
    @Published public private(set) var lastError: String?
    @Published public private(set) var modelState: SpeechEngineState = .unloaded

    public var idleUnloadSeconds: TimeInterval = 600

    private let engine: any SpeechEngine
    private let normalizer: TextNormalizer
    private let chunker: TextChunker

    private var producerTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var sessionDirectory: URL?
    private var activeSessionID: UUID?
    private let audioEngine = AVAudioEngine()
    private let audioPlayerNode = AVAudioPlayerNode()
    private let maximumScheduledAudioCount = 2
    private var isAudioEngineConfigured = false
    private var scheduledAudio: [ScheduledAudio] = []
    private var backpressureContinuations: [CheckedContinuation<Void, Never>] = []
    private var producerFinished = false

    public init(
        engine: any SpeechEngine,
        normalizer: TextNormalizer = TextNormalizer(),
        chunker: TextChunker = TextChunker()
    ) {
        self.engine = engine
        self.normalizer = normalizer
        self.chunker = chunker
        super.init()
    }

    deinit {
        producerTask?.cancel()
        idleUnloadTask?.cancel()
    }

    public func read(
        _ text: String,
        source: CaptureSource,
        voice: SpeechVoice,
        speed: Double
    ) {
        stop(clearSession: true)
        idleUnloadTask?.cancel()

        let normalized = normalizer.normalize(text)
        let chunks = chunker.chunks(from: normalized)

        guard !chunks.isEmpty else {
            status = .failed("No readable text found")
            return
        }

        captureSource = source
        totalChunks = chunks.count
        currentChunkIndex = 0
        queuedChunks = 0
        producerFinished = false
        let sessionID = UUID()
        activeSessionID = sessionID
        lastError = nil
        modelState = .loading
        status = .preparing

        let outputDirectory: URL
        do {
            outputDirectory = try AppPaths.makeSessionDirectory()
            sessionDirectory = outputDirectory
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let pipeline = SpeechSynthesisPipeline(engine: engine)
        producerTask = Task { [weak self] in
            do {
                try await pipeline.synthesize(
                    chunks: chunks,
                    voice: voice,
                    speed: speed,
                    outputDirectory: outputDirectory
                ) { [weak self] audio in
                    guard let self else {
                        throw CancellationError()
                    }
                    try await self.enqueue(audio, sessionID: sessionID)
                }
                self?.finishProducing(sessionID: sessionID)
            } catch is CancellationError {
                self?.finishProducing(sessionID: sessionID)
            } catch {
                self?.fail(error, sessionID: sessionID)
            }
        }
    }

    public func pause() {
        guard status == .playing else {
            return
        }
        audioPlayerNode.pause()
        status = .paused
    }

    public func resume() {
        guard status == .paused else {
            return
        }
        do {
            try ensureAudioEngineIsRunning()
            audioPlayerNode.play()
            status = .playing
        } catch {
            fail(error)
        }
    }

    public func togglePause() {
        if status == .playing {
            pause()
        } else if status == .paused {
            resume()
        }
    }

    public func skipCurrent() {
        guard !scheduledAudio.isEmpty else {
            return
        }

        let remainingAudio = scheduledAudio.dropFirst().map(\.chunk)
        audioPlayerNode.stop()
        scheduledAudio.removeAll()
        queuedChunks = 0

        for audio in remainingAudio {
            schedule(audio)
        }

        if scheduledAudio.isEmpty, producerFinished {
            completeSession()
        } else if status != .paused {
            startPlaybackIfNeeded()
        }
        resumeBackpressureWaitersIfNeeded()
    }

    public func stop(clearSession: Bool = true, cancelEngine: Bool = true) {
        producerTask?.cancel()
        producerTask = nil
        audioPlayerNode.stop()
        audioEngine.stop()
        scheduledAudio.removeAll()
        queuedChunks = 0
        resumeBackpressureWaiters()
        producerFinished = true
        activeSessionID = nil
        status = .idle

        if cancelEngine {
            Task {
                await engine.cancel()
            }
        }

        if clearSession {
            removeSessionDirectory()
        }

        scheduleIdleUnload()
    }

    public func unloadNow() {
        stop(clearSession: true, cancelEngine: false)
        idleUnloadTask?.cancel()
        modelState = .unloaded
        Task {
            await engine.cancel()
            await engine.unload()
        }
    }

    private func enqueue(_ audio: SynthesizedAudioChunk, sessionID: UUID) async throws {
        guard activeSessionID == sessionID else {
            throw CancellationError()
        }
        if modelState != .unloaded {
            modelState = .ready
        }
        schedule(audio)
        startPlaybackIfNeeded()
        try await waitForQueueCapacity(sessionID: sessionID)
    }

    private func finishProducing(sessionID: UUID) {
        guard activeSessionID == sessionID else {
            return
        }
        producerTask = nil
        producerFinished = true
        if scheduledAudio.isEmpty {
            completeSession()
        }
    }

    private func fail(_ error: any Error, sessionID: UUID? = nil) {
        if let sessionID, activeSessionID != sessionID {
            return
        }
        lastError = error.localizedDescription
        status = .failed(error.localizedDescription)
        producerTask = nil
        producerFinished = true
        activeSessionID = nil
        resumeBackpressureWaiters()
        if modelState != .unloaded {
            modelState = .ready
        }
        scheduleIdleUnload()
    }

    private func schedule(_ audio: SynthesizedAudioChunk) {
        do {
            try configureAudioEngineIfNeeded()
            let file = try AVAudioFile(forReading: audio.fileURL)
            let scheduled = ScheduledAudio(chunk: audio, file: file)
            scheduledAudio.append(scheduled)
            updatePlaybackProgress()

            let sessionID = activeSessionID
            audioPlayerNode.scheduleFile(
                file,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.finishPlaying(audio, sessionID: sessionID)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func startPlaybackIfNeeded() {
        guard !scheduledAudio.isEmpty, status != .paused else {
            return
        }

        do {
            try ensureAudioEngineIsRunning()
            if !audioPlayerNode.isPlaying {
                audioPlayerNode.play()
            }
            status = .playing
        } catch {
            fail(error)
        }
    }

    private func finishPlaying(_ audio: SynthesizedAudioChunk, sessionID: UUID?) {
        guard activeSessionID == sessionID else {
            return
        }

        if let first = scheduledAudio.first, first.chunk.id == audio.id {
            scheduledAudio.removeFirst()
        } else {
            scheduledAudio.removeAll { $0.chunk.id == audio.id }
        }

        updatePlaybackProgress()

        if scheduledAudio.isEmpty {
            if producerFinished {
                completeSession()
            } else if status != .paused {
                status = .preparing
            }
        }
        resumeBackpressureWaitersIfNeeded()
    }

    private func waitForQueueCapacity(sessionID: UUID) async throws {
        while activeSessionID == sessionID && scheduledAudio.count > maximumScheduledAudioCount {
            await withCheckedContinuation { continuation in
                backpressureContinuations.append(continuation)
            }
        }

        if activeSessionID != sessionID || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func resumeBackpressureWaitersIfNeeded() {
        guard scheduledAudio.count <= maximumScheduledAudioCount else {
            return
        }
        resumeBackpressureWaiters()
    }

    private func resumeBackpressureWaiters() {
        let continuations = backpressureContinuations
        backpressureContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func updatePlaybackProgress() {
        if let current = scheduledAudio.first?.chunk {
            currentChunkIndex = current.chunkIndex + 1
        }
        queuedChunks = max(0, scheduledAudio.count - 1)
    }

    private func configureAudioEngineIfNeeded() throws {
        guard !isAudioEngineConfigured else {
            return
        }

        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: nil)
        isAudioEngineConfigured = true
    }

    private func ensureAudioEngineIsRunning() throws {
        try configureAudioEngineIfNeeded()
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }

    private func completeSession() {
        status = totalChunks > 0 ? .completed : .idle
        currentChunkIndex = totalChunks
        activeSessionID = nil
        audioPlayerNode.stop()
        audioEngine.stop()
        scheduledAudio.removeAll()
        queuedChunks = 0
        resumeBackpressureWaiters()
        scheduleIdleUnload()
        removeSessionDirectory()
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let seconds = idleUnloadSeconds
        idleUnloadTask = Task { [engine] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await engine.unload()
                await MainActor.run {
                    self.modelState = .unloaded
                }
            } catch {}
        }
    }

    private func removeSessionDirectory() {
        guard let sessionDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: sessionDirectory)
        self.sessionDirectory = nil
    }
}

private struct ScheduledAudio {
    let chunk: SynthesizedAudioChunk
    let file: AVAudioFile
}
