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
              Self.isValidAuthority(in: text, components: components),
              let url = components.url
        else {
            return nil
        }

        return url
    }

    private static func isValidAuthority(in text: String, components: URLComponents) -> Bool {
        guard let encodedHost = components.percentEncodedHost,
              !encodedHost.isEmpty,
              !encodedHost.contains("%"),
              let host = components.host,
              !host.isEmpty,
              host.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              let authority = Self.authority(in: text),
              Self.hasValidRawPort(in: authority, parsedPort: components.port),
              Self.isValidPort(components.port)
        else {
            return false
        }

        return true
    }

    private static func authority(in text: String) -> Substring? {
        guard let separator = text.range(of: "://") else {
            return nil
        }

        let start = separator.upperBound
        let end = text[start...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? text.endIndex
        let authority = text[start..<end]

        return authority.isEmpty ? nil : authority
    }

    private static func hasValidRawPort(in authority: Substring, parsedPort: Int?) -> Bool {
        let hostPortStart: Substring.Index
        if let userInfoEnd = authority.lastIndex(of: "@") {
            hostPortStart = authority.index(after: userInfoEnd)
        } else {
            hostPortStart = authority.startIndex
        }

        let hostPort = authority[hostPortStart...]
        guard !hostPort.isEmpty else {
            return false
        }

        if hostPort.first == "[" {
            guard let hostEnd = hostPort.firstIndex(of: "]") else {
                return false
            }

            let portStart = hostPort.index(after: hostEnd)
            let portSegment = hostPort[portStart...]
            guard !portSegment.isEmpty else {
                return true
            }
            guard portSegment.first == ":" else {
                return false
            }

            return Self.isValidRawPortText(portSegment.dropFirst(), parsedPort: parsedPort)
        }

        guard let portSeparator = hostPort.lastIndex(of: ":") else {
            return true
        }

        let portText = hostPort[hostPort.index(after: portSeparator)...]
        return Self.isValidRawPortText(portText, parsedPort: parsedPort)
    }

    private static func isValidRawPortText(_ portText: Substring, parsedPort: Int?) -> Bool {
        guard !portText.isEmpty,
              portText.allSatisfy(\.isASCIIDigit),
              let parsedPort
        else {
            return false
        }

        return Self.isValidPort(parsedPort)
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
    nonisolated var isASCIIDigit: Bool {
        guard unicodeScalars.count == 1,
              let scalar = unicodeScalars.first
        else {
            return false
        }

        return (0x30...0x39).contains(scalar.value)
    }

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
