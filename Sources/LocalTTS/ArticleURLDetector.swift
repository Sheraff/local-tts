import Foundation

enum ArticleURLDetector {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048, !trimmed.contains(where: \.isNewline) else {
            return nil
        }

        if let directURL = validArticleURL(from: trimmed) {
            return directURL
        }

        let candidate = "https://\(trimmed)"
        if trimmed.contains("."), !trimmed.contains(" "), let inferredURL = validArticleURL(from: candidate) {
            return inferredURL
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = detector.matches(in: trimmed, range: range)
        guard matches.count == 1, let match = matches.first, match.range == range, let url = match.url else {
            return nil
        }

        return isReadableScheme(url) ? url : nil
    }

    private static func validArticleURL(from text: String) -> URL? {
        guard let url = URL(string: text), isReadableScheme(url), url.host != nil else {
            return nil
        }
        return url
    }

    private static func isReadableScheme(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }
}
