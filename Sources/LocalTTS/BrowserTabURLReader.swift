import AppKit
import Foundation

struct BrowserTabURLReader {
    private let browsers: [Browser] = [
        Browser(applicationName: "Safari", urlScript: #"tell application "Safari" to get URL of front document"#),
        Browser(applicationName: "Google Chrome", urlScript: #"tell application "Google Chrome" to get URL of active tab of front window"#),
        Browser(applicationName: "Microsoft Edge", urlScript: #"tell application "Microsoft Edge" to get URL of active tab of front window"#),
        Browser(applicationName: "Brave Browser", urlScript: #"tell application "Brave Browser" to get URL of active tab of front window"#),
        Browser(applicationName: "Arc", urlScript: #"tell application "Arc" to get URL of active tab of front window"#),
    ]

    func activeTabURL() throws -> URL {
        let runningBrowserNames = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        )
        let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName

        if let frontmostBrowser = browsers.first(where: { $0.applicationName == frontmostName }),
           let url = try? readURL(from: frontmostBrowser)
        {
            return url
        }

        for browser in browsers where runningBrowserNames.contains(browser.applicationName) {
            if let url = try? readURL(from: browser) {
                return url
            }
        }

        throw BrowserTabError.noReadableBrowserTab
    }

    private func readURL(from browser: Browser) throws -> URL {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: browser.urlScript) else {
            throw BrowserTabError.scriptFailed(browser.applicationName, "Could not create AppleScript")
        }

        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Automation failed"
            throw BrowserTabError.scriptFailed(browser.applicationName, message)
        }

        guard let text = descriptor.stringValue,
              let url = ArticleURLDetector.url(from: text)
        else {
            throw BrowserTabError.scriptFailed(browser.applicationName, "Active tab does not contain a readable URL")
        }

        return url
    }
}

private struct Browser {
    let applicationName: String
    let urlScript: String
}

enum BrowserTabError: LocalizedError {
    case noReadableBrowserTab
    case scriptFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .noReadableBrowserTab:
            "No supported browser tab URL found"
        case let .scriptFailed(browser, message):
            "\(browser): \(message)"
        }
    }
}
