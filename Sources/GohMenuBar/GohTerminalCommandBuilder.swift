import Foundation
import GohCore

nonisolated public enum GohTerminalCommand: Sendable, Equatable {
    case top
    case doctor

    var arguments: [String] {
        switch self {
        case .top:
            return ["top"]
        case .doctor:
            return ["doctor"]
        }
    }
}

nonisolated public struct GohTerminalCommandBuilder: Sendable {
    private let companionExecutablePath: String
    private let environment: [String: String]

    public init(
        companionExecutablePath: String,
        environment: [String: String]
    ) {
        self.companionExecutablePath = companionExecutablePath
        self.environment = environment
    }

    public func command(for terminalCommand: GohTerminalCommand) -> String {
        let gohPath = URL(filePath: companionExecutablePath)
            .deletingLastPathComponent()
            .appending(path: "goh")
            .path
        let command = ([gohPath] + terminalCommand.arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")

        guard let peerRelaxation = environment[GohXPCService.developmentRelaxationEnvironmentKey] else {
            return command
        }

        return "export \(GohXPCService.developmentRelaxationEnvironmentKey)=\(Self.shellQuoted(peerRelaxation)); \(command)"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
