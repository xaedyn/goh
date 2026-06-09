import Foundation
import Testing

import GohCore

@Suite("Command schema wire forms")
struct CommandTests {

    private func wire<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try CommandCoding.encoder.encode(value), as: UTF8.self)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try CommandCoding.decoder.decode(T.self, from: CommandCoding.encoder.encode(value))
    }

    @Test("AddRequest round-trips, minimal and full")
    func addRequestRoundTrip() throws {
        let minimal = AddRequest(url: "https://example.com/f.iso")
        #expect(try roundTrip(minimal) == minimal)

        let full = AddRequest(
            url: "https://example.com/f.iso",
            destination: "/tmp/f.iso",
            connectionCount: 16,
            useImportedCookies: false,
            priority: .high)
        #expect(try roundTrip(full) == full)
    }

    @Test("RmRequest round-trips, with and without keepPartialFile")
    func rmRequestRoundTrip() throws {
        let bare = RmRequest(jobID: 7)
        #expect(try roundTrip(bare) == bare)
        let kept = RmRequest(jobID: 7, keepPartialFile: true)
        #expect(try roundTrip(kept) == kept)
    }

    @Test("AuthImportSafari request and reply round-trip")
    func authImportSafariRequestAndReplyRoundTrip() throws {
        let request = AuthImportSafariRequest()
        #expect(try roundTrip(request) == request)

        let reply = AuthImportSafariReply(importedCookieCount: 42)
        #expect(try roundTrip(reply) == reply)
    }

    @Test("Subscribe request and progress reply round-trip")
    func subscribeRequestAndReplyRoundTrip() throws {
        let jobRequest = SubscribeRequest(scope: .job, jobID: 42)
        #expect(try roundTrip(jobRequest) == jobRequest)

        let allRequest = SubscribeRequest(scope: .all)
        #expect(try roundTrip(allRequest) == allRequest)

        let reply = SubscribeReply(revision: 7, snapshot: [])
        #expect(try roundTrip(reply) == reply)
    }

    @Test("Progress event round-trips with lane-level detail")
    func progressEventRoundTrip() throws {
        let job = JobSummary(
            id: 42,
            url: "https://example.com/big.zip",
            destination: "/Users/me/Downloads/big.zip",
            state: .active,
            progress: JobProgress(
                bytesCompleted: 1024,
                bytesTotal: 4096,
                bytesPerSecond: 512),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastProgressAt: Date(timeIntervalSince1970: 1_700_000_001),
            requestedConnectionCount: 8,
            actualConnectionCount: 2)
        let lane = TransferLaneProgress(
            index: 1,
            state: .active,
            rangeStart: 1024,
            rangeEnd: 2047,
            bytesCompleted: 512,
            bytesTotal: 1024,
            bytesPerSecond: 256,
            protocolName: "h2",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_002))
        let event = ProgressEvent(
            sequence: 3,
            revision: 9,
            emittedAt: Date(timeIntervalSince1970: 1_700_000_003),
            updateKind: .fullSnapshot,
            snapshot: [ProgressSnapshot(job: job, lanes: [lane])])

        #expect(try roundTrip(event) == event)
    }

    @Test("every Command case round-trips")
    func commandRoundTrip() throws {
        let commands: [Command] = [
            .add(request: AddRequest(url: "https://example.com/f")),
            .ls,
            .pause(jobID: 3),
            .resume(jobID: 3),
            .rm(request: RmRequest(jobID: 3)),
            .authImportSafari(request: AuthImportSafariRequest()),
            .subscribe(request: SubscribeRequest(scope: .job, jobID: 3)),
            .recordVerifiedProvenance(request: RecordVerifiedProvenanceRequest(entries: [
                VerifiedProvenanceEntry(
                    url: "https://example.com/f.bin",
                    sha256: "sha256:" + String(repeating: "c", count: 64),
                    size: 512,
                    destinationPath: "/tmp/f.bin",
                    verifiedAt: Date(timeIntervalSince1970: 1_750_000_000)),
            ])),
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    @Test("RecordVerifiedProvenanceRequest and VerifiedProvenanceEntry round-trip")
    func recordVerifiedProvenancePayloadRoundTrip() throws {
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            destinationPath: "/Users/u/Downloads/f.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let request = RecordVerifiedProvenanceRequest(entries: [entry])
        #expect(try roundTrip(request) == request)
        let reply = AckReply()
        #expect(try roundTrip(reply) == reply)
    }

    @Test("LsReply and RmReply round-trip")
    func replyRoundTrip() throws {
        let rm = RmReply(removedJobID: 9)
        #expect(try roundTrip(rm) == rm)
        let ls = LsReply(jobs: [])
        #expect(try roundTrip(ls) == ls)
    }

    @Test("progress subscription enums encode to their frozen wire strings")
    func progressSubscriptionEnumWireStrings() throws {
        #expect(try wire(SubscriptionScope.job) == "\"job\"")
        #expect(try wire(SubscriptionScope.all) == "\"all\"")
        #expect(try wire(ProgressUpdateKind.fullSnapshot) == "\"fullSnapshot\"")
        #expect(try wire(TransferLaneState.pending) == "\"pending\"")
        #expect(try wire(TransferLaneState.active) == "\"active\"")
        #expect(try wire(TransferLaneState.completed) == "\"completed\"")
        #expect(try wire(TransferLaneState.failed) == "\"failed\"")
    }
}

// ── AC8: VerifiedProvenanceEntry additive-optional wire fields ───────────────

@Suite("VerifiedProvenanceEntry wire fields")
struct VerifiedProvenanceEntryWireTests {

    // AC8: protocolVersion stays 4.
    @Test("AC8: CommandService protocolVersion stays 4")
    func protocolVersionUnchanged() {
        #expect(CommandService.protocolVersion == 4)
    }

    // AC8: new fields default nil; Codable round-trip preserves them.
    @Test("AC8: additive-optional fields survive Codable round-trip")
    func additiveOptionalRoundTrip() throws {
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/file.bin",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            size: 1024,
            destinationPath: "/Users/u/Downloads/file.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_748_000_000),
            recordedStatSize: 1024,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 123_456_789,
            recordedInode: 987654321,
            recordedDevice: 16777220)

        let data = try CommandCoding.encoder.encode(entry)
        let decoded = try CommandCoding.decoder.decode(VerifiedProvenanceEntry.self, from: data)

        #expect(decoded.recordedStatSize == 1024)
        #expect(decoded.recordedMtimeSeconds == 1_748_000_000)
        #expect(decoded.recordedMtimeNanoseconds == 123_456_789)
        #expect(decoded.recordedInode == 987654321)
        #expect(decoded.recordedDevice == 16777220)
    }

    // AC8: nil fields are absent from JSON (backward-compatible).
    @Test("AC8: nil stat fields absent from encoded JSON")
    func nilFieldsAbsentFromJSON() throws {
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/f.bin",
            sha256: "sha256:" + String(repeating: "b", count: 64),
            size: 512,
            destinationPath: "/tmp/f.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_000_000_000))
        // All 5 recordedStat* default nil.
        let data = try CommandCoding.encoder.encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("recordedStatSize"))
        #expect(!json.contains("recordedMtimeSeconds"))
    }

    // AC10: recordedStatSize is sourced from stat.size (Int64), not the display size (Int).
    // Verify the type is Int64 (the fstat field type).
    @Test("AC10: recordedStatSize field type is Int64 (matching fstat st_size)")
    func recordedStatSizeIsInt64() throws {
        let statSize: Int64 = 73_741_824  // 70.3 MB
        let entry = VerifiedProvenanceEntry(
            url: "https://example.com/large.bin",
            sha256: "sha256:" + String(repeating: "c", count: 64),
            size: Int(statSize),  // happens to be equal for a normal file
            destinationPath: "/tmp/large.bin",
            verifiedAt: Date(timeIntervalSince1970: 1_748_000_000),
            recordedStatSize: statSize,
            recordedMtimeSeconds: 1_748_000_000,
            recordedMtimeNanoseconds: 0,
            recordedInode: 12345,
            recordedDevice: 16777220)
        let data = try CommandCoding.encoder.encode(entry)
        let decoded = try CommandCoding.decoder.decode(VerifiedProvenanceEntry.self, from: data)
        #expect(decoded.recordedStatSize == statSize)
    }
}
