import LocalTTSCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var player: SpeechPlaybackCoordinator

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        player = model.player
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                manualReader
                statusPanel
                modelPanel
                diagnosticsPanel
                shortcutPanel
                runtimePanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local TTS")
                .font(.title)
                .fontWeight(.semibold)
            Text("Read selected text or clipboard\(settings.hotKeyEnabled ? " with \(settings.shortcut.displayText)" : "").")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Voice", selection: $settings.selectedVoiceID) {
                ForEach(model.voices) { voice in
                    Text("\(voice.name) · \(voice.language)").tag(voice.id)
                }
            }
            .frame(maxWidth: 260)

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed \(settings.speed, specifier: "%.2f")x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.speed, in: 0.75...1.6, step: 0.05)
                    .frame(width: 160)
            }

            Spacer()
        }
    }

    private var manualReader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $model.manualText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .frame(minHeight: 190)

            HStack {
                Button {
                    model.readSelectionOrClipboard()
                } label: {
                    Label("Read Selection or Clipboard", systemImage: "text.viewfinder")
                }

                Button {
                    model.readManualText()
                } label: {
                    Label("Read Text", systemImage: "play.fill")
                }
                .disabled(model.manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    model.togglePause()
                } label: {
                    Label(player.status == .paused ? "Resume" : "Pause", systemImage: player.status == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(!model.canTogglePause)

                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }

                Spacer()
            }
        }
    }

    private var statusPanel: some View {
        section("Status") {
            LabeledContent("Playback", value: player.status.displayText)
            LabeledContent("Progress", value: "\(player.currentChunkIndex) / \(player.totalChunks)")
            LabeledContent("Queued", value: "\(player.queuedChunks)")
            LabeledContent("Capture", value: player.captureSource.rawValue)
            LabeledContent("Selected voice", value: selectedVoiceText)
            LabeledContent("Permission", value: model.permissionStatus)

            if model.hasAccessibilityPermission {
                Label("Selected-text capture is enabled", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    model.requestAccessibilityPermission()
                } label: {
                    Label("Grant Accessibility Permission", systemImage: "checkmark.shield")
                }
            }
        }
    }

    private var modelPanel: some View {
        section("Model") {
            LabeledContent("Status", value: model.modelStatus)
            LabeledContent("Runtime", value: player.modelState.displayText)
            LabeledContent("Path", value: AppPaths.kokoroModelDirectory.path)

            if model.isDownloadingModel {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.modelDownloadFraction)
                    Text(model.modelDownloadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.cancelModelDownload()
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else if model.isModelInstalled {
                if !model.hasFullPrecisionModel {
                    Button {
                        model.downloadFullPrecisionModel()
                    } label: {
                        Label("Download Higher Quality Model", systemImage: "arrow.down.circle")
                    }
                }

                if model.missingEnglishVoiceCount > 0 {
                    Button {
                        model.downloadMissingEnglishVoices()
                    } label: {
                        Label("Download More Voices", systemImage: "person.wave.2")
                    }
                }

                Button(role: .destructive) {
                    model.deleteKokoroAssets()
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            } else {
                Button {
                    model.downloadKokoroAssets()
                } label: {
                    Label("Download Kokoro Assets", systemImage: "arrow.down.circle")
                }

                if !model.modelDownloadStatus.isEmpty {
                    Text(model.modelDownloadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                model.unloadNow()
            } label: {
                Label("Unload Model Now", systemImage: "memorychip")
            }
            .disabled(!model.canUnloadModel)
        }
    }

    private var shortcutPanel: some View {
        section("Shortcut") {
            Toggle("Enable global shortcut", isOn: $settings.hotKeyEnabled)

            LabeledContent("Current", value: model.hotKeyStatus)

            LabeledContent("Recorder") {
                ShortcutRecorderView(shortcut: $settings.shortcut)
                    .frame(width: 220)
                    .disabled(!settings.hotKeyEnabled)
                    .opacity(settings.hotKeyEnabled ? 1 : 0.55)
            }

            Text("Click the recorder, then press a shortcut using Command, Option, or Control.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsPanel: some View {
        section("Diagnostics") {
            LabeledContent("App", value: Bundle.main.bundleURL.path)
            LabeledContent("Executable", value: Bundle.main.executableURL?.path ?? "Unknown")
            LabeledContent("Frontend", value: model.frontendStatus)
            LabeledContent("Backend", value: model.frontendBackend)
            LabeledContent("eSpeak data", value: model.frontendDataPath)

            if !model.frontendAmericanSample.isEmpty {
                LabeledContent("US sample", value: model.frontendAmericanSample)
            }
            if !model.frontendBritishSample.isEmpty {
                LabeledContent("UK sample", value: model.frontendBritishSample)
            }

            Button {
                model.refreshFrontendDiagnostics()
            } label: {
                Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
            }
        }
    }

    private var runtimePanel: some View {
        section("Runtime") {
            LabeledContent("Idle unload") {
                HStack {
                    Slider(value: $settings.idleUnloadMinutes, in: 1...60, step: 1)
                    Text("\(settings.idleUnloadMinutes, specifier: "%.0f") min")
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                .frame(maxWidth: 300)
            }
        }
    }

    private var selectedVoiceText: String {
        guard let voice = model.selectedVoice else {
            return "None (\(settings.selectedVoiceID))"
        }
        return "\(voice.name) \(voice.id)"
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
