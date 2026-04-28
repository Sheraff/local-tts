import Foundation

public struct KokoroDownloadProgress: Equatable, Sendable {
    public let currentFileName: String
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentFileFraction: Double
    public let isFinished: Bool

    public var fraction: Double {
        if isFinished {
            return 1
        }
        guard totalFiles > 0 else {
            return 0
        }
        return (Double(completedFiles) + currentFileFraction) / Double(totalFiles)
    }

    public var displayText: String {
        if isFinished {
            "Kokoro assets downloaded"
        } else {
            "Downloading \(currentFileName) \(Int((currentFileFraction * 100).rounded()))% (\(completedFiles)/\(totalFiles))"
        }
    }
}

public struct KokoroAssetFile: Equatable, Sendable {
    public let remotePath: String
    public let localPath: String
    public let displayName: String

    public init(remotePath: String, localPath: String? = nil, displayName: String? = nil) {
        self.remotePath = remotePath
        self.localPath = localPath ?? remotePath
        self.displayName = displayName ?? URL(fileURLWithPath: remotePath).lastPathComponent
    }
}

public actor KokoroAssetDownloader {
    public static let repositoryBaseURL = URL(
        string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/"
    )!

    public static let defaultFiles: [KokoroAssetFile] = [
        KokoroAssetFile(remotePath: "config.json"),
        KokoroAssetFile(remotePath: "tokenizer.json"),
        KokoroAssetFile(remotePath: "tokenizer_config.json"),
        KokoroAssetFile(remotePath: "onnx/model_quantized.onnx", displayName: "model_quantized.onnx"),
    ] + englishVoiceFiles

    public static let englishVoiceFiles: [KokoroAssetFile] = KokoroVoiceCatalog.englishVoices.map {
        KokoroAssetFile(remotePath: "voices/\($0.id).bin")
    }

    public static let fullPrecisionModelFiles: [KokoroAssetFile] = [
        KokoroAssetFile(remotePath: "onnx/model.onnx", displayName: "model.onnx"),
    ]

    private let destinationDirectory: URL
    private let baseURL: URL
    private let files: [KokoroAssetFile]

    public init(
        destinationDirectory: URL = AppPaths.kokoroModelDirectory,
        baseURL: URL = KokoroAssetDownloader.repositoryBaseURL,
        files: [KokoroAssetFile] = KokoroAssetDownloader.defaultFiles
    ) {
        self.destinationDirectory = destinationDirectory
        self.baseURL = baseURL
        self.files = files
    }

    public func download(
        progress: @escaping @Sendable (KokoroDownloadProgress) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var completedFiles = 0
        for asset in files {
            try Task.checkCancellation()

            await progress(
                KokoroDownloadProgress(
                    currentFileName: asset.displayName,
                    completedFiles: completedFiles,
                    totalFiles: files.count,
                    currentFileFraction: 0,
                    isFinished: false
                )
            )

            let destination = destinationDirectory.appendingPathComponent(asset.localPath)
            if hasUsableFile(at: destination) {
                completedFiles += 1
                continue
            }

            try await download(
                asset,
                to: destination,
                completedFiles: completedFiles,
                totalFiles: files.count,
                progress: progress
            )
            completedFiles += 1
        }

        await progress(
            KokoroDownloadProgress(
                currentFileName: "",
                completedFiles: completedFiles,
                totalFiles: files.count,
                currentFileFraction: 1,
                isFinished: true
            )
        )
    }

    private func download(
        _ asset: KokoroAssetFile,
        to destination: URL,
        completedFiles: Int,
        totalFiles: Int,
        progress: @escaping @Sendable (KokoroDownloadProgress) async -> Void
    ) async throws {
        let source = baseURL.appendingPathComponent(asset.remotePath)
        let delegate = AssetDownloadDelegate { receivedBytes, expectedBytes in
            let fileFraction = expectedBytes > 0
                ? min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
                : 0
            await progress(
                KokoroDownloadProgress(
                    currentFileName: asset.displayName,
                    completedFiles: completedFiles,
                    totalFiles: totalFiles,
                    currentFileFraction: fileFraction,
                    isFinished: false
                )
            )
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let temporaryURL = try await delegate.download(from: source, using: session, displayName: asset.displayName)
        session.finishTasksAndInvalidate()

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let partialDestination = destination.appendingPathExtension("download")
        if FileManager.default.fileExists(atPath: partialDestination.path) {
            try FileManager.default.removeItem(at: partialDestination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: partialDestination)
        try FileManager.default.moveItem(at: partialDestination, to: destination)
    }

    private func hasUsableFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return false
        }

        return fileSize.intValue > 0
    }
}

private final class AssetDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var downloadedURL: URL?
    private var terminalError: (any Error)?

    init(progress: @escaping @Sendable (Int64, Int64) async -> Void) {
        self.progress = progress
    }

    func download(from source: URL, using session: URLSession, displayName: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task {
            await progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let persistentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalTTS-\(UUID().uuidString).download")
            if FileManager.default.fileExists(atPath: persistentURL.path) {
                try FileManager.default.removeItem(at: persistentURL)
            }
            try FileManager.default.moveItem(at: location, to: persistentURL)

            lock.lock()
            downloadedURL = persistentURL
            lock.unlock()
        } catch {
            lock.lock()
            terminalError = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            resume(.failure(error))
            return
        }

        if let terminalError {
            resume(.failure(terminalError))
            return
        }

        if let httpResponse = task.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode)
        {
            resume(
                .failure(
                    SpeechEngineError.synthesisFailed("Could not download asset: HTTP \(httpResponse.statusCode)")
                )
            )
            return
        }

        guard let downloadedURL else {
            resume(.failure(SpeechEngineError.synthesisFailed("Download completed without a file")))
            return
        }

        resume(.success(downloadedURL))
    }

    private func resume(_ result: Result<URL, any Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case let .success(url):
            continuation?.resume(returning: url)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}
