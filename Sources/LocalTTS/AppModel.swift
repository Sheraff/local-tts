import AppKit
import Foundation
import LocalTTSCore

@MainActor
final class AppModel: ObservableObject {
    @Published var voices: [SpeechVoice] = []
    @Published var manualText = ""
    @Published var permissionStatus = "Accessibility permission not checked"
    @Published var modelStatus = "Model status not checked"
    @Published var modelDownloadStatus = ""
    @Published var modelDownloadFraction = 0.0
    @Published var isDownloadingModel = false
    @Published var hasAccessibilityPermission = false
    @Published var isModelInstalled = false
    @Published var hasFullPrecisionModel = false
    @Published var missingEnglishVoiceCount = 0
    @Published var frontendStatus = "Frontend not checked"
    @Published var frontendBackend = "Not resolved"
    @Published var frontendDataPath = "Not resolved"
    @Published var frontendAmericanSample = ""
    @Published var frontendBritishSample = ""

    let settings: AppSettings
    let player: SpeechPlaybackCoordinator
    let hotKeyManager: GlobalHotKeyManager

    private let captureService: TextCaptureService
    private let engine: KokoroOnnxEngine
    private var downloadTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init() {
        settings = AppSettings()
        engine = KokoroOnnxEngine()
        player = SpeechPlaybackCoordinator(engine: engine)
        hotKeyManager = GlobalHotKeyManager()
        captureService = TextCaptureService()

        player.idleUnloadSeconds = settings.idleUnloadMinutes * 60
        settings.onHotKeySettingsChanged = { [weak self] in
            self?.applyHotKeySettings()
        }
        hotKeyManager.onHotKey = { [weak self] in
            self?.readSelectionOrClipboard()
        }
        applyHotKeySettings()

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refresh()
                }
            }
        )

        Task {
            await refresh()
        }
    }

    var selectedVoice: SpeechVoice? {
        voices.first { $0.id == settings.selectedVoiceID } ?? voices.first
    }

    var canTogglePause: Bool {
        player.status == .playing || player.status == .paused
    }

    var canUnloadModel: Bool {
        player.modelState != .unloaded
    }

    private var isPlaybackActive: Bool {
        switch player.status {
        case .preparing, .playing, .paused:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    var hotKeyStatus: String {
        if !settings.hotKeyEnabled {
            return "Disabled"
        }
        if hotKeyManager.isRegistered {
            return settings.shortcut.displayText
        }
        return hotKeyManager.errorMessage ?? "Not registered"
    }

    func refresh() async {
        hasAccessibilityPermission = captureService.isAccessibilityTrusted
        permissionStatus = hasAccessibilityPermission
            ? "Accessibility permission granted"
            : "Accessibility permission needed for selected text"

        let assetStatus = await engine.assetStatus()
        isModelInstalled = assetStatus.isComplete
        hasFullPrecisionModel = assetStatus.hasFullPrecisionModel
        missingEnglishVoiceCount = assetStatus.missingEnglishVoiceCount
        modelStatus = assetStatus.displayText
        refreshFrontendDiagnostics()

        do {
            voices = try await engine.listVoices()
            if selectedVoice == nil, let first = voices.first {
                settings.selectedVoiceID = first.id
            }
        } catch {
            voices = []
            modelStatus = error.localizedDescription
        }
    }

    func refreshFrontendDiagnostics() {
        let diagnostics = KokoroTextFrontend.diagnostics()
        frontendStatus = diagnostics.displayText
        frontendBackend = diagnostics.backend
        frontendDataPath = diagnostics.dataPath
        frontendAmericanSample = diagnostics.americanSample ?? ""
        frontendBritishSample = diagnostics.britishSample ?? ""
    }

    func applyHotKeySettings() {
        if settings.hotKeyEnabled {
            hotKeyManager.register(settings.shortcut)
        } else {
            hotKeyManager.unregister()
        }
    }

    func requestAccessibilityPermission() {
        _ = captureService.requestAccessibilityPermission()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refresh()
        }
    }

    func readSelectionOrClipboard() {
        guard let captured = captureService.capturePreferredText() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        read(captured.text, source: captured.source)
    }

    func readManualText() {
        read(manualText, source: .manual)
    }

    func read(_ text: String, source: CaptureSource) {
        guard let selectedVoice else {
            return
        }

        player.idleUnloadSeconds = settings.idleUnloadMinutes * 60
        player.read(
            text,
            source: source,
            voice: selectedVoice,
            speed: settings.speed
        )
    }

    func stop() {
        player.stop()
    }

    func togglePause() {
        player.togglePause()
    }

    func unloadNow() {
        guard canUnloadModel else {
            return
        }
        player.unloadNow()
        Task {
            await refresh()
        }
    }

    func downloadKokoroAssets() {
        downloadKokoroAssets(
            files: KokoroAssetDownloader.defaultFiles,
            startingStatus: "Starting download",
            completedStatus: "Download complete",
            unloadLoadedModel: false
        )
    }

    func downloadFullPrecisionModel() {
        downloadKokoroAssets(
            files: KokoroAssetDownloader.fullPrecisionModelFiles,
            startingStatus: "Starting full-precision model download",
            completedStatus: "Full-precision model downloaded",
            unloadLoadedModel: true
        )
    }

    func downloadMissingEnglishVoices() {
        downloadKokoroAssets(
            files: KokoroAssetDownloader.englishVoiceFiles,
            startingStatus: "Starting voice download",
            completedStatus: "Voices downloaded",
            unloadLoadedModel: false
        )
    }

    private func downloadKokoroAssets(
        files: [KokoroAssetFile],
        startingStatus: String,
        completedStatus: String,
        unloadLoadedModel: Bool
    ) {
        guard !isDownloadingModel else {
            return
        }

        isDownloadingModel = true
        modelDownloadStatus = startingStatus
        modelDownloadFraction = 0

        downloadTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let downloader = KokoroAssetDownloader(files: files)
                try await downloader.download { progress in
                    await MainActor.run {
                        self.modelDownloadStatus = progress.displayText
                        self.modelDownloadFraction = progress.fraction
                    }
                }

                await MainActor.run {
                    self.isDownloadingModel = false
                    self.modelDownloadStatus = completedStatus
                    if unloadLoadedModel, !self.isPlaybackActive {
                        self.player.unloadNow()
                    }
                }
                await self.refresh()
            } catch is CancellationError {
                await MainActor.run {
                    self.isDownloadingModel = false
                    self.modelDownloadStatus = "Download cancelled"
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingModel = false
                    self.modelDownloadStatus = error.localizedDescription
                }
                await self.refresh()
            }
        }
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloadingModel = false
        modelDownloadStatus = "Download cancelled"
    }

    func deleteKokoroAssets() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloadingModel = false

        Task {
            player.unloadNow()
            await engine.unload()

            do {
                if FileManager.default.fileExists(atPath: AppPaths.kokoroModelDirectory.path) {
                    try FileManager.default.removeItem(at: AppPaths.kokoroModelDirectory)
                }
                modelDownloadStatus = "Model deleted"
            } catch {
                modelDownloadStatus = error.localizedDescription
            }

            await refresh()
        }
    }
}
