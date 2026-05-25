import Foundation

nonisolated public struct GohClipboardURLDetector: Sendable {
    public init() {}

    public func url(from rawText: String?) -> URL? {
        guard let rawText else {
            return nil
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
                      && !CharacterSet.controlCharacters.contains(scalar)
              }),
              Self.hasOnlyValidPercentEscapes(text)
        else {
            return nil
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              Self.isValidPort(components.port),
              let url = components.url
        else {
            return nil
        }

        return url
    }

    private static func isValidPort(_ port: Int?) -> Bool {
        guard let port else {
            return true
        }

        return (1...65_535).contains(port)
    }

    private static func hasOnlyValidPercentEscapes(_ text: String) -> Bool {
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "%" else {
                index = text.index(after: index)
                continue
            }

            let firstHexIndex = text.index(after: index)
            guard firstHexIndex < text.endIndex else {
                return false
            }

            let secondHexIndex = text.index(after: firstHexIndex)
            guard secondHexIndex < text.endIndex,
                  text[firstHexIndex].isASCIIHexDigit,
                  text[secondHexIndex].isASCIIHexDigit
            else {
                return false
            }

            index = text.index(after: secondHexIndex)
        }

        return true
    }
}

private extension Character {
    nonisolated var isASCIIHexDigit: Bool {
        guard unicodeScalars.count == 1,
              let scalar = unicodeScalars.first
        else {
            return false
        }

        return (0x30...0x39).contains(scalar.value)
            || (0x41...0x46).contains(scalar.value)
            || (0x61...0x66).contains(scalar.value)
    }
}
