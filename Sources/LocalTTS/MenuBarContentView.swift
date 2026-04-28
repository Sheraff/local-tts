import LocalTTSCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var player: SpeechPlaybackCoordinator

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        player = model.player
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform")
                Text(player.status.displayText)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(player.currentChunkIndex)/\(player.totalChunks)")
                    .foregroundStyle(.secondary)
            }

            Picker("Voice", selection: $settings.selectedVoiceID) {
                ForEach(model.voices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed \(settings.speed, specifier: "%.2f")x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.speed, in: 0.75...1.6, step: 0.05)
            }

            HStack {
                Button {
                    model.readSelectionOrClipboard()
                } label: {
                    Label("Read", systemImage: "text.viewfinder")
                }

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
            }

            Divider()

            Text("Shortcut: \(model.hotKeyStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.unloadNow()
            } label: {
                Label("Unload Model", systemImage: "memorychip")
            }
            .disabled(!model.canUnloadModel)

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Show Local TTS", systemImage: "macwindow")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .padding(14)
    }
}
