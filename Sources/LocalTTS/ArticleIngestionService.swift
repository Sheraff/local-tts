import AppKit
import Foundation
import Readability
import WebKit

@MainActor
final class ArticleIngestionService {
    private let readability = Readability()
    private let renderedHTMLLoader = RenderedHTMLLoader()

    func extractArticle(from url: URL) async throws -> ExtractedArticle {
        var firstError: (any Error)?

        do {
            let html = try await fetchHTML(from: url)
            let result = try await readability.parse(html: html, options: nil, baseURL: url)
            let article = try makeArticle(from: result, url: url, extractionMode: "Direct HTML")
            if article.body.count >= 200 {
                return article
            }
            firstError = ArticleIngestionError.articleTooShort
        } catch {
            firstError = error
        }

        do {
            let html = try await renderedHTMLLoader.loadHTML(from: url)
            let result = try await readability.parse(html: html, options: nil, baseURL: url)
            return try makeArticle(from: result, url: url, extractionMode: "Rendered page")
        } catch {
            throw ArticleIngestionError.extractionFailed(
                directError: firstError?.localizedDescription,
                renderedError: error.localizedDescription
            )
        }
    }

    private func fetchHTML(from url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X 15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) LocalTTS/0.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode)
        {
            throw ArticleIngestionError.httpStatus(httpResponse.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1),
            !html.isEmpty
        else {
            throw ArticleIngestionError.invalidHTML
        }

        return html
    }

    private func makeArticle(
        from result: ReadabilityResult,
        url: URL,
        extractionMode: String
    ) throws -> ExtractedArticle {
        let body = cleanArticleText(html: result.content) ?? cleanPlainText(result.textContent)
        guard body.count >= 80 else {
            throw ArticleIngestionError.articleTooShort
        }

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if title.isEmpty || body.localizedCaseInsensitiveContains(title) {
            text = body
        } else {
            text = "\(title)\n\n\(body)"
        }

        return ExtractedArticle(
            url: url,
            title: title.isEmpty ? url.host(percentEncoded: false) ?? url.absoluteString : title,
            siteName: result.siteName,
            body: body,
            readableText: text,
            extractionMode: extractionMode
        )
    }

    private func cleanArticleText(html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let attributedString = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              )
        else {
            return nil
        }

        return cleanPlainText(attributedString.string)
    }

    private func cleanPlainText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }

        var result: [String] = []
        var previousWasBlank = true

        for line in lines {
            if line.isEmpty {
                if !previousWasBlank {
                    result.append("")
                }
                previousWasBlank = true
            } else {
                result.append(line)
                previousWasBlank = false
            }
        }

        return result
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExtractedArticle: Sendable {
    let url: URL
    let title: String
    let siteName: String?
    let body: String
    let readableText: String
    let extractionMode: String

    var displaySource: String {
        if let siteName, !siteName.isEmpty {
            return "\(siteName) · \(extractionMode)"
        }
        return "\(url.host(percentEncoded: false) ?? url.absoluteString) · \(extractionMode)"
    }
}

enum ArticleIngestionError: LocalizedError {
    case articleTooShort
    case httpStatus(Int)
    case invalidHTML
    case extractionFailed(directError: String?, renderedError: String)

    var errorDescription: String? {
        switch self {
        case .articleTooShort:
            return "Readability could not find enough article text"
        case let .httpStatus(statusCode):
            return "Article request failed with HTTP \(statusCode)"
        case .invalidHTML:
            return "Article response was not readable HTML"
        case let .extractionFailed(directError, renderedError):
            if let directError {
                return "Article extraction failed. Direct fetch: \(directError). Rendered fallback: \(renderedError)"
            }
            return "Article extraction failed. Rendered fallback: \(renderedError)"
        }
    }
}

@MainActor
private final class RenderedHTMLLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, any Error>?

    func loadHTML(from url: URL) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()

                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.navigationDelegate = self
                self.webView = webView

                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            do {
                let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = value as? String, !html.isEmpty else {
                    finish(.failure(ArticleIngestionError.articleTooShort))
                    return
                }
                finish(.success(html))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        switch result {
        case let .success(html):
            continuation.resume(returning: html)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
