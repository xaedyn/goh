import Foundation

public struct GohDoctorProbes {
    public var executablePath: String
    public var daemonExecutablePath: String
    public var launchAgentPath: String
    public var downloadsDirectoryPath: String
    public var logsDirectoryPath: String
    public var logPath: String
    public var environment: [String: String]
    public var userID: () -> Int
    public var fileExists: (String) -> Bool
    public var isExecutableFile: (String) -> Bool
    public var isWritableDirectory: (String) -> Bool
    public var fileContents: (String) -> String?
    public var launchctlPrint: (String) -> Bool
    public var readQueue: () throws -> LsReply

    public init(
        executablePath: String,
        daemonExecutablePath: String,
        launchAgentPath: String,
        downloadsDirectoryPath: String,
        logsDirectoryPath: String,
        logPath: String,
        environment: [String: String],
        userID: @escaping () -> Int,
        fileExists: @escaping (String) -> Bool,
        isExecutableFile: @escaping (String) -> Bool,
        isWritableDirectory: @escaping (String) -> Bool,
        fileContents: @escaping (String) -> String?,
        launchctlPrint: @escaping (String) -> Bool,
        readQueue: @escaping () throws -> LsReply
    ) {
        self.executablePath = executablePath
        self.daemonExecutablePath = daemonExecutablePath
        self.launchAgentPath = launchAgentPath
        self.downloadsDirectoryPath = downloadsDirectoryPath
        self.logsDirectoryPath = logsDirectoryPath
        self.logPath = logPath
        self.environment = environment
        self.userID = userID
        self.fileExists = fileExists
        self.isExecutableFile = isExecutableFile
        self.isWritableDirectory = isWritableDirectory
        self.fileContents = fileContents
        self.launchctlPrint = launchctlPrint
        self.readQueue = readQueue
    }
}

public struct GohDoctor {
    private enum Severity {
        case ok
        case warning
        case failure

        var label: String {
            switch self {
            case .ok:
                return "ok"
            case .warning:
                return "warn"
            case .failure:
                return "fail"
            }
        }
    }

    private struct Finding {
        var severity: Severity
        var title: String
        var detail: String?
        var recovery: String?
    }

    private let probes: GohDoctorProbes

    public init(probes: GohDoctorProbes) {
        self.probes = probes
    }

    public func run() -> GohCommandLineResult {
        let findings = collectFindings()
        let hasFailure = findings.contains { $0.severity == .failure }
        let hasWarning = findings.contains { $0.severity == .warning }

        var output = "goh doctor\n"
        output += findings.map(format).joined()
        output += "\n"
        if hasFailure {
            output += "Needs attention.\n"
        } else if hasWarning {
            output += "Healthy with warnings.\n"
        } else {
            output += "Healthy.\n"
        }

        return GohCommandLineResult(
            exitCode: hasFailure ? 1 : 0,
            standardOutput: output)
    }

    private func collectFindings() -> [Finding] {
        let serviceTarget = "gui/\(probes.userID())/\(GohXPCService.machServiceName)"
        var findings: [Finding] = []

        findings.append(executableFinding(
            title: "CLI executable",
            path: probes.executablePath,
            recovery: "Run: Scripts/dogfood-build.sh"))
        findings.append(executableFinding(
            title: "daemon executable",
            path: probes.daemonExecutablePath,
            recovery: "Run: Scripts/dogfood-build.sh"))
        findings.append(launchAgentFinding())
        let daemonLoaded = probes.launchctlPrint(serviceTarget)
        findings.append(Finding(
            severity: daemonLoaded ? .ok : .failure,
            title: "daemon loaded: \(serviceTarget)",
            detail: nil,
            recovery: daemonLoaded ? nil : dogfoodInstallRecovery()))
        findings.append(peerValidationFinding())
        findings.append(contentsOf: xpcFindings())
        findings.append(directoryFinding(
            title: "downloads directory writable",
            path: probes.downloadsDirectoryPath,
            recovery: "Run: mkdir -p \(shellQuoted(probes.downloadsDirectoryPath))"))
        findings.append(directoryFinding(
            title: "logs directory writable",
            path: probes.logsDirectoryPath,
            recovery: "Run: mkdir -p \(shellQuoted(probes.logsDirectoryPath))"))
        findings.append(logFinding())

        return findings
    }

    private func executableFinding(
        title: String,
        path: String,
        recovery: String
    ) -> Finding {
        if probes.isExecutableFile(path) {
            return Finding(severity: .ok, title: "\(title): \(path)", detail: nil, recovery: nil)
        }
        if probes.fileExists(path) {
            return Finding(
                severity: .failure,
                title: "\(title): \(path)",
                detail: "File exists but is not executable.",
                recovery: "Run: chmod +x \(shellQuoted(path))")
        }
        return Finding(
            severity: .failure,
            title: "\(title): \(path)",
            detail: "File is missing.",
            recovery: recovery)
    }

    private func launchAgentFinding() -> Finding {
        guard probes.fileExists(probes.launchAgentPath) else {
            return Finding(
                severity: .failure,
                title: "LaunchAgent installed: \(probes.launchAgentPath)",
                detail: "The per-user daemon plist is missing.",
                recovery: dogfoodInstallRecovery())
        }

        guard isDogfoodInstall else {
            return Finding(
                severity: .ok,
                title: "LaunchAgent installed: \(probes.launchAgentPath)",
                detail: nil,
                recovery: nil)
        }

        let contents = probes.fileContents(probes.launchAgentPath) ?? ""
        guard contents.contains("goh dogfood local LaunchAgent"),
              contents.contains(".build/dogfood")
        else {
            return Finding(
                severity: .failure,
                title: "LaunchAgent installed: \(probes.launchAgentPath)",
                detail: "The plist exists, but it is not the marked local dogfood LaunchAgent.",
                recovery: dogfoodInstallRecovery())
        }

        return Finding(
            severity: .ok,
            title: "LaunchAgent installed: \(probes.launchAgentPath)",
            detail: nil,
            recovery: nil)
    }

    private func xpcFindings() -> [Finding] {
        do {
            let reply = try probes.readQueue()
            return [
                Finding(
                    severity: .ok,
                    title: "XPC reachable",
                    detail: nil,
                    recovery: nil),
                Finding(
                    severity: .ok,
                    title: "queue readable: \(jobCount(reply.jobs.count))",
                    detail: nil,
                    recovery: nil),
            ]
        } catch {
            return [
                Finding(
                    severity: .failure,
                    title: "XPC reachable",
                    detail: "Could not reach gohd: \(error)",
                    recovery: xpcRecovery()),
            ]
        }
    }

    private func peerValidationFinding() -> Finding {
        guard isDogfoodInstall else {
            return Finding(
                severity: .ok,
                title: "peer validation: enforced",
                detail: nil,
                recovery: nil)
        }

        let key = GohXPCService.developmentRelaxationEnvironmentKey
        if probes.environment[key] != nil {
            return Finding(
                severity: .ok,
                title: "peer validation: dogfood relaxation enabled",
                detail: nil,
                recovery: nil)
        }

        return Finding(
            severity: .warning,
            title: "peer validation: dogfood relaxation is not enabled",
            detail: "Unsigned debug dogfood binaries need this in the shell that runs goh.",
            recovery: dogfoodPeerRelaxationRecovery())
    }

    private func directoryFinding(
        title: String,
        path: String,
        recovery: String
    ) -> Finding {
        if probes.isWritableDirectory(path) {
            return Finding(severity: .ok, title: "\(title): \(path)", detail: nil, recovery: nil)
        }
        if probes.fileExists(path) {
            return Finding(
                severity: .failure,
                title: "\(title): \(path)",
                detail: "Path exists but is not a writable directory.",
                recovery: recovery)
        }
        return Finding(
            severity: .failure,
            title: "\(title): \(path)",
            detail: "Directory is missing.",
            recovery: recovery)
    }

    private func logFinding() -> Finding {
        guard isDogfoodInstall else {
            return Finding(
                severity: .ok,
                title: "daemon log path: \(probes.logPath)",
                detail: nil,
                recovery: nil)
        }

        if probes.fileExists(probes.logPath) {
            return Finding(
                severity: .ok,
                title: "daemon log: \(probes.logPath)",
                detail: nil,
                recovery: nil)
        }
        return Finding(
            severity: .warning,
            title: "daemon log: \(probes.logPath)",
            detail: "No log file yet. This is normal before launchd writes stdout or stderr.",
            recovery: "Run: Scripts/dogfood-install.sh")
    }

    private func format(_ finding: Finding) -> String {
        var text = "[\(finding.severity.label)] \(finding.title)\n"
        if let detail = finding.detail, !detail.isEmpty {
            text += "     \(detail)\n"
        }
        if let recovery = finding.recovery, !recovery.isEmpty {
            text += "     \(recovery)\n"
        }
        return text
    }

    private var isDogfoodInstall: Bool {
        probes.executablePath.contains("/.build/dogfood/")
    }

    private func dogfoodInstallRecovery() -> String {
        if isDogfoodInstall {
            return "Run: Scripts/dogfood-install.sh"
        }
        return "Run: brew services restart goh"
    }

    private func xpcRecovery() -> String {
        if isDogfoodInstall,
           probes.environment[GohXPCService.developmentRelaxationEnvironmentKey] == nil
        {
            return dogfoodPeerRelaxationRecovery()
        }
        return dogfoodInstallRecovery()
    }

    private func dogfoodPeerRelaxationRecovery() -> String {
        "Run: export \(GohXPCService.developmentRelaxationEnvironmentKey)=1"
    }

    private func jobCount(_ count: Int) -> String {
        count == 1 ? "1 job" : "\(count) jobs"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
