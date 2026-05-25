import Foundation

nonisolated public struct GohClipboardURLDetector: Sendable {
    public init() {}

    public func url(from rawText: String?) -> URL? {
        guard let rawText else {
            return nil
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\r") else {
            return nil
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else {
            return nil
        }

        return url
    }
}
