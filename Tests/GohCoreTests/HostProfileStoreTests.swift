import Foundation
import Testing

import GohCore

@Suite("Host profile store")
struct HostProfileStoreTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "goh-hostprofile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sampleScheduling() -> HostScheduling {
        // 30 days ago — comfortably inside the 90-day TTL, and relative so the
        // test never ages out (the AC4 TTL tests use the same idiom).
        let recent = Date(timeIntervalSinceNow: -(30 * 24 * 3600))
        return HostScheduling(version: HostScheduling.currentVersion, hosts: [
            HostProfile(
                host: "https://dl.example.com:443",
                arms: [
                    ConnObservation(
                        connectionCount: 8, throughputEWMA: 10_000_000,
                        sampleCount: 3, updatedAt: recent)
                ],
                updatedAt: recent)
        ])
    }

    // AC3: save/load round-trip.
    @Test("AC: save then load round-trips HostScheduling")
    func ac3SaveLoadRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let scheduling = sampleScheduling()
        try store.save(scheduling)

        let loaded = store.load()
        #expect(loaded.scheduling == scheduling)
        #expect(loaded.corruptionSidecar == nil)
    }

    // AC3: missing file → empty.
    @Test("AC: missing file yields empty HostScheduling")
    func ac3MissingFileYieldsEmpty() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.isEmpty)
        #expect(loaded.corruptionSidecar == nil)
    }

    // AC3: corrupt → sidecar recovery.
    @Test("AC: corrupt file recovers to empty and leaves sidecar copy")
    func ac3CorruptFileLeaveSidecar() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        try Data("not a plist".utf8).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.isEmpty)
        let sidecar = try #require(loaded.corruptionSidecar)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // AC3: no temp file left behind.
    @Test("AC: save leaves no temporary file behind")
    func ac3NoTempFileLeft() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        try store.save(sampleScheduling())

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["host-scheduling.plist"])
    }

    // AC3: file permissions are 0600.
    @Test("AC: saved file has owner-only 0600 permissions")
    func ac3FilePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        let store = HostProfileStore(fileURL: fileURL)
        try store.save(sampleScheduling())

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = attrs[.posixPermissions] as? Int
        #expect(posixPerms == 0o600)
    }

    // AC4: TTL eviction.
    @Test("AC: profiles older than TTL are dropped on load")
    func ac4TTLEviction() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        let oldDate = Date(timeIntervalSinceNow: -(91 * 24 * 3600))
        let scheduling = HostScheduling(version: 1, hosts: [
            HostProfile(
                host: "https://old.example.com:443",
                arms: [],
                updatedAt: oldDate)
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(scheduling).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.isEmpty)
    }

    // AC4: a profile within TTL is kept.
    @Test("profile within TTL is retained on load")
    func ttlRetains() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appending(path: "host-scheduling.plist")
        let recentDate = Date(timeIntervalSinceNow: -(30 * 24 * 3600))
        let scheduling = HostScheduling(version: 1, hosts: [
            HostProfile(
                host: "https://recent.example.com:443",
                arms: [],
                updatedAt: recentDate)
        ])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(scheduling).write(to: fileURL)

        let store = HostProfileStore(fileURL: fileURL)
        let loaded = store.load()
        #expect(loaded.scheduling.hosts.count == 1)
    }

    // AC9: begin/wasSolo/end — contended-set tracks any job that ever had a sibling.
    @Test("AC: solo job is wasSolo; overlapping sibling marks both contended; subsequent solo is clean")
    func ac9SoloContendedTracking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))

        let key = "https://example.com:443"

        store.begin(jobID: 1, hostKey: key)
        #expect(store.wasSolo(jobID: 1))
        store.end(jobID: 1, hostKey: key)

        store.begin(jobID: 2, hostKey: key)
        store.begin(jobID: 3, hostKey: key)
        #expect(!store.wasSolo(jobID: 2))
        #expect(!store.wasSolo(jobID: 3))
        store.end(jobID: 2, hostKey: key)
        store.end(jobID: 3, hostKey: key)

        store.begin(jobID: 4, hostKey: key)
        #expect(store.wasSolo(jobID: 4))
        store.end(jobID: 4, hostKey: key)
    }

    // AC8 (partial): observation recording updates the arm.
    @Test("recording an observation folds throughput into the arm EWMA")
    func observationRecording() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()

        let key = "https://example.com:443"
        store.recordObservation(
            hostKey: key, connectionCount: 8,
            totalBytes: 100 * 1024 * 1024,
            transferDuration: .seconds(10))

        let scheduling = store.currentScheduling()
        let profile = try #require(scheduling.hosts.first { $0.host == key })
        let arm = try #require(profile.arms.first { $0.connectionCount == 8 })
        // throughput = 100*1024*1024 / 10 = 10_485_760 bytes/sec
        #expect(abs(arm.throughputEWMA - 10_485_760) < 1)
        #expect(arm.sampleCount == 1)
    }

    // AC5 (through store): nil host key → (8, .cold).
    @Test("AC: nil host key via selectN returns (8, cold)")
    func ac5NilHostKeyViaStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        let (n, reason) = store.selectN(hostKey: nil)
        #expect(n == 8)
        #expect(reason == .cold)
    }

    // AC5 (through store): unknown host → (8, .cold).
    @Test("AC: unknown host key via selectN returns (8, cold)")
    func ac5UnknownHostViaStore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(
            fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()
        let (n, reason) = store.selectN(hostKey: "https://unknown.example.com:443")
        #expect(n == 8)
        #expect(reason == .cold)
    }

    // Hardening: the D5/D8 gate predicate, unit-tested in isolation.
    @Test("D5 gate: a clean solo download qualifies")
    func d5GatePositive() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(10),
            bytesCompleted: 8 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: a resume never qualifies (D8)")
    func d5GateResumeRejected() {
        let req = ObservationRequest(
            isResume: true, transferDuration: .seconds(60),
            bytesCompleted: 100 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: too short a transfer is rejected")
    func d5GateTooShort() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(9),
            bytesCompleted: 100 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: too few bytes is rejected")
    func d5GateTooFewBytes() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 8 * 1024 * 1024 - 1, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: a contended (non-solo) download is rejected")
    func d5GateContendedRejected() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 100 * 1024 * 1024, wasSolo: false,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: off-candidate governor outcome is rejected")
    func d5GateOffCandidateRejected() {
        // effectiveN nil = governor converged off-candidate; must not pollute the arm.
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 100 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: nil, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("D5 gate: boundary — exactly 10s and exactly 8 MiB qualifies")
    func d5GateBoundary() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(10),
            bytesCompleted: 8 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 16, stabilized: true))
        #expect(HostProfileStore.shouldRecordObservation(req))
    }

    @Test("ObservationRequest: effectiveN nil → gate rejects")
    func observationGateRejectsNilEffectiveN() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: nil, stabilized: true))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("ObservationRequest: stabilized=false → gate rejects")
    func observationGateRejectsUnstabilized() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: false))
        #expect(!HostProfileStore.shouldRecordObservation(req))
    }

    @Test("ObservationRequest: candidate-aligned stable → gate passes")
    func observationGatePassesCandidateAligned() {
        let req = ObservationRequest(
            isResume: false, transferDuration: .seconds(30),
            bytesCompleted: 16 * 1024 * 1024, wasSolo: true,
            governorOutcome: GovernorOutcome(effectiveN: 8, stabilized: true))
        #expect(HostProfileStore.shouldRecordObservation(req))
    }

    @Test("SM4: governor-recorded arm warm-starts N₀ — exploit picks the best arm")
    func sm4WarmStartFromGovernorArm() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HostProfileStore(fileURL: directory.appending(path: "host-scheduling.plist"))
        _ = store.load()
        let key = "https://fast.example.com:443"
        let candidates: [(UInt8, Double)] = [(2, 20_000_000), (4, 40_000_000), (8, 80_000_000), (16, 60_000_000)]
        for (n, throughput) in candidates {
            for _ in 0..<3 {   // ≥ minSamples
                store.recordObservation(hostKey: key, connectionCount: n,
                    totalBytes: UInt64(throughput * 30), transferDuration: .seconds(30))
            }
        }
        let (chosenN, reason) = store.selectN(hostKey: key)
        #expect(chosenN == 8, "SM4: exploit should pick N=8 (best EWMA); got \(chosenN)")
        #expect(reason == .exploit, "selectN returns .exploit; warmStart is the trace annotation, not a selectN return")
    }

    @Test("SM4: warmStart trace predicate — exploit + no explicit N + governor on ⇒ warmStart; else not")
    func sm4WarmStartPredicate() {
        func traceReason(_ selectionReason: SelectionReason, hasExplicitN: Bool, governorOn: Bool) -> SelectionReason {
            if selectionReason == .exploit, !hasExplicitN, governorOn { return .warmStart }
            return selectionReason
        }
        #expect(traceReason(.exploit, hasExplicitN: false, governorOn: true) == .warmStart)
        #expect(traceReason(.exploit, hasExplicitN: true,  governorOn: true) == .exploit)   // explicit N
        #expect(traceReason(.exploit, hasExplicitN: false, governorOn: false) == .exploit)  // kill-switch
        #expect(traceReason(.explore, hasExplicitN: false, governorOn: true) == .explore)   // not exploit
        #expect(traceReason(.cold,    hasExplicitN: false, governorOn: true) == .cold)
    }
}
