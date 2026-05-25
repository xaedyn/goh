import Foundation
import Testing

import GohCore

@Suite("goh doctor")
struct GohDoctorTests {

    @Test("healthy dogfood install reports every critical check as ok")
    func healthyDogfoodInstallReportsOK() {
        let paths = DoctorPaths()
        let probes = Self.probes(paths: paths)

        let result = GohDoctor(probes: probes).run()

        #expect(result.exitCode == 0)
        #expect(result.standardError == "")
        #expect(result.standardOutput.hasPrefix("Get over here!\n\ngoh doctor\n"))
        #expect(result.standardOutput.contains("[ok] CLI executable: \(paths.goh)"))
        #expect(result.standardOutput.contains("[ok] daemon executable: \(paths.gohd)"))
        #expect(result.standardOutput.contains("[ok] LaunchAgent installed: \(paths.launchAgent)"))
        #expect(result.standardOutput.contains("[ok] daemon loaded: gui/501/dev.goh.daemon"))
        #expect(result.standardOutput.contains("[ok] XPC reachable"))
        #expect(result.standardOutput.contains("[ok] peer validation: dogfood relaxation enabled"))
        #expect(result.standardOutput.contains("[ok] downloads directory writable: \(paths.downloads)"))
        #expect(result.standardOutput.contains("[ok] logs directory writable: \(paths.logs)"))
        #expect(result.standardOutput.contains("[ok] queue readable: 1 job"))
        #expect(!result.standardOutput.contains("Run:"))
        #expect(result.standardOutput.hasSuffix("Healthy.\n"))
    }

    @Test("missing daemon surfaces exact dogfood recovery command")
    func missingDaemonSurfacesRecoveryCommand() {
        let paths = DoctorPaths()
        let probes = Self.probes(
            paths: paths,
            existing: [paths.goh, paths.gohd, paths.downloads, paths.logs],
            launchctlLoaded: false,
            queueResult: .failure(TestTransportError()))

        let result = GohDoctor(probes: probes).run()

        #expect(result.exitCode == 1)
        #expect(result.standardError == "")
        #expect(result.standardOutput.contains("[fail] LaunchAgent installed: \(paths.launchAgent)"))
        #expect(result.standardOutput.contains("Run: Scripts/dogfood-install.sh"))
        #expect(result.standardOutput.contains("[fail] daemon loaded: gui/501/dev.goh.daemon"))
        #expect(result.standardOutput.contains("[fail] XPC reachable"))
        #expect(result.standardOutput.contains("Could not reach gohd: test transport failure"))
        #expect(result.standardOutput.hasSuffix("Needs attention.\n"))
    }

    @Test("dogfood without peer-relaxation environment is a warning, not a failure")
    func missingDogfoodPeerRelaxationWarns() {
        let paths = DoctorPaths()
        let probes = Self.probes(paths: paths, environment: [:])

        let result = GohDoctor(probes: probes).run()

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("[warn] peer validation: dogfood relaxation is not enabled"))
        #expect(result.standardOutput.contains("Run: export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
        #expect(result.standardOutput.hasSuffix("Healthy with warnings.\n"))
    }

    @Test("dogfood peer validation failure points at the local shell export")
    func dogfoodPeerValidationFailurePointsAtLocalShellExport() {
        let paths = DoctorPaths()
        let probes = Self.probes(
            paths: paths,
            environment: [:],
            queueResult: .failure(TestTransportError()))

        let result = GohDoctor(probes: probes).run()

        #expect(result.exitCode == 1)
        #expect(result.standardOutput.contains("[fail] XPC reachable"))
        #expect(result.standardOutput.contains("Run: export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1"))
    }

    private static func probes(
        paths: DoctorPaths,
        existing: Set<String>? = nil,
        executable: Set<String>? = nil,
        writable: Set<String>? = nil,
        environment: [String: String] = ["GOH_XPC_ALLOW_UNVALIDATED_PEERS": "1"],
        launchctlLoaded: Bool = true,
        queueResult: Result<LsReply, Error> = .success(LsReply(jobs: [
            makeJob(id: 6, state: .completed),
        ]))
    ) -> GohDoctorProbes {
        let existing = existing ?? [
            paths.goh,
            paths.gohd,
            paths.launchAgent,
            paths.downloads,
            paths.logs,
            paths.logFile,
        ]
        let executable = executable ?? [paths.goh, paths.gohd]
        let writable = writable ?? [paths.downloads, paths.logs]
        return GohDoctorProbes(
            executablePath: paths.goh,
            daemonExecutablePath: paths.gohd,
            launchAgentPath: paths.launchAgent,
            downloadsDirectoryPath: paths.downloads,
            logsDirectoryPath: paths.logs,
            logPath: paths.logFile,
            environment: environment,
            userID: { 501 },
            fileExists: { existing.contains($0) },
            isExecutableFile: { executable.contains($0) },
            isWritableDirectory: { writable.contains($0) },
            fileContents: { path in
                path == paths.launchAgent
                    ? "<!-- goh dogfood local LaunchAgent. Safe to remove with Scripts/dogfood-reset.sh. -->\n.build/dogfood\n"
                    : nil
            },
            launchctlPrint: { target in
                launchctlLoaded && target == "gui/501/dev.goh.daemon"
            },
            readQueue: {
                switch queueResult {
                case .success(let reply):
                    return reply
                case .failure(let error):
                    throw error
                }
            })
    }

    private static func makeJob(id: UInt64, state: JobState) -> JobSummary {
        JobSummary(
            id: id,
            url: "https://example.com/file",
            destination: "/tmp/file",
            state: state,
            progress: JobProgress(
                bytesCompleted: 0,
                bytesTotal: nil,
                bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            lastProgressAt: nil,
            requestedConnectionCount: 8,
            actualConnectionCount: 0)
    }

    private struct DoctorPaths {
        let goh = "/repo/.build/dogfood/current/bin/goh"
        let gohd = "/repo/.build/dogfood/current/bin/gohd"
        let launchAgent = "/Users/test/Library/LaunchAgents/dev.goh.daemon.plist"
        let downloads = "/repo/.build/dogfood/downloads"
        let logs = "/repo/.build/dogfood/logs"
        let logFile = "/repo/.build/dogfood/logs/goh.log"
    }

    private struct TestTransportError: Error, CustomStringConvertible {
        var description: String { "test transport failure" }
    }
}
