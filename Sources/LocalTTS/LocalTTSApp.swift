import SwiftUI

@main
struct LocalTTSApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--diagnose") {
            LocalTTSDiagnostics.runAndExit()
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window("Local TTS", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 640)
        }

        MenuBarExtra("Local TTS", systemImage: "waveform") {
            MenuBarContentView(model: model)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
