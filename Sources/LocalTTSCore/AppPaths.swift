import Foundation

public enum AppPaths {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LocalTTS", isDirectory: true)
    }

    public static var modelDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    public static var kokoroModelDirectory: URL {
        modelDirectory.appendingPathComponent("Kokoro-82M-v1.0-ONNX", isDirectory: true)
    }

    public static func ensureRuntimeDirectories() throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    public static func makeSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTTS", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
