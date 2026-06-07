import Foundation
import Testing
import GohCore
@testable import GohMenuBar

// ── Stub: FolderPicker ────────────────────────────────────────────────────────

@MainActor
private final class StubFolderPicker: FolderPicker {
    var result: String?      // nil = simulates cancel
    nonisolated init(result: String? = nil) { self.result = result }
    func chooseFolder() async -> String? { result }
}

// ── Stub: FakeMenuClient (parallel to GohMenuViewModelTests.swift) ────────────

@MainActor
private final class FakeMenuClient: GohMenuClient {
    var addedRequests: [AddRequest] = []
    var addError: (any Error)?

    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func add(_ request: AddRequest) async throws -> JobSummary {
        if let addError { throw addError }
        addedRequests.append(request)
        return JobSummary(
            id: 1,
            url: request.url,
            destination: "/tmp/big.iso",
            state: .queued,
            progress: JobProgress(bytesCompleted: 0, bytesTotal: nil, bytesPerSecond: 0),
            createdAt: Date(timeIntervalSince1970: 1),
            lastProgressAt: nil,
            requestedConnectionCount: request.connectionCount ?? 8,
            actualConnectionCount: 0)
    }

    func pause(jobID: UInt64) async throws {}
    func resume(jobID: UInt64) async throws {}
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws {}
}

// ── GohMenuError.userFacingMessage — direct per-case tests ───────────────────

@Suite("GohMenuError.userFacingMessage")
struct GohMenuErrorUserFacingMessageTests {

    // AC5 / §7.3: each case returns a plain sentence; no enum name, no String(describing:)

    @Test func daemonUnavailableIsPlainSentence() {
        let msg = GohMenuError.daemonUnavailable("some detail").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("daemonUnavailable"))
        #expect(msg.hasSuffix("."))
    }

    @Test func peerValidationIsPlainSentence() {
        let msg = GohMenuError.peerValidation("some peer error").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("peerValidation"))
        #expect(msg.hasSuffix("."))
    }

    @Test func protocolMismatchIsPlainSentence() {
        let msg = GohMenuError.protocolMismatch("v2 vs v3").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("protocolMismatch"))
        #expect(msg.hasSuffix("."))
    }

    @Test func daemonErrorIncludesContextSentence() {
        let gohError = GohError(code: .protocolVersionMismatch, message: "v1 != v2")
        let msg = GohMenuError.daemon(gohError).userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("daemon("))
        #expect(msg.hasSuffix(".") || msg.hasSuffix(")"))
    }

    @Test func malformedReplyIsPlainSentence() {
        let msg = GohMenuError.malformedReply("unexpected field").userFacingMessage
        #expect(!msg.isEmpty)
        #expect(!msg.contains("malformedReply"))
        #expect(msg.hasSuffix("."))
    }
}

// ── AddDownloadViewModel tests ────────────────────────────────────────────────

@Suite("AddDownloadViewModel")
@MainActor
struct AddDownloadViewModelTests {

    // AC1: folder chosen → destination set in AddRequest
    @Test func folderChosenSetsDestination() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Movies")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()
        #expect(vm.chosenFolder == "/Users/test/Movies")

        let success = await vm.submit()
        #expect(success)
        #expect(client.addedRequests.first?.destination == "/Users/test/Movies")
    }

    // AC1: no folder chosen → destination nil
    @Test func noFolderChosenLeavesDestinationNil() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: nil)  // simulates cancel
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()     // cancelled pick; chosenFolder stays nil
        let success = await vm.submit()
        #expect(success)
        #expect(client.addedRequests.first?.destination == nil)
    }

    // §7.2: cancelled pick leaves chosenFolder UNCHANGED (not cleared)
    @Test func cancelledPickLeavesChosenFolderUnchanged() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Prior")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()     // sets /Users/test/Prior
        #expect(vm.chosenFolder == "/Users/test/Prior")

        picker.result = nil         // now cancel
        await vm.chooseFolder()     // cancel — must NOT clear
        #expect(vm.chosenFolder == "/Users/test/Prior")
    }

    // useDefaultFolder clears chosenFolder → nil
    @Test func useDefaultFolderClearsChosen() async {
        let client = FakeMenuClient()
        let picker = StubFolderPicker(result: "/Users/test/Movies")
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: picker)

        await vm.chooseFolder()
        #expect(vm.chosenFolder == "/Users/test/Movies")
        vm.useDefaultFolder()
        #expect(vm.chosenFolder == nil)
    }

    // AC2: automatic ON → connectionCount nil
    @Test func automaticOnSendsNilConnectionCount() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = true
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == nil)
    }

    // AC2: pinned count is sent as the exact UInt8
    @Test func pinnedCountSendsExactUInt8() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 6
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 6)
    }

    // AC3: out-of-range count 0 clamps to 1 (never traps)
    @Test func outOfRangeZeroClampedToOne() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 0          // below 1
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 1)
    }

    // AC3: out-of-range count 99 clamps to 16 (never traps)
    @Test func outOfRangeHighClampedToSixteen() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        vm.automaticConnections = false
        vm.connectionCount = 99         // above 16
        _ = await vm.submit()
        #expect(client.addedRequests.first?.connectionCount == 16)
    }

    // §7.2: submitted url == detector's normalized absoluteString, not raw text
    @Test func submitsNormalizedURL() async {
        // The detector normalizes via URLComponents; give a URL that survives the trip
        let rawURL = "https://example.com/file.iso"
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: rawURL,
            client: client,
            folderPicker: StubFolderPicker())

        _ = await vm.submit()
        let sent = client.addedRequests.first?.url
        // Must equal the detector's normalized absoluteString — not the raw text
        let expected = GohClipboardURLDetector().url(from: rawURL)?.absoluteString
        #expect(sent == expected)
    }

    // canAdd == false for various invalid inputs
    @Test func canAddFalseForEmptyString() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = ""
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForWhitespace() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "   "
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForBareWord() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "foo"
        #expect(vm.canAdd == false)
    }

    @Test func canAddFalseForFileURL() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "file:///Users/test/file.iso"
        #expect(vm.canAdd == false)
    }

    @Test func canAddTrueForValidHTTPS() {
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: FakeMenuClient(),
            folderPicker: StubFolderPicker())
        vm.urlText = "https://example.com/big.iso"
        #expect(vm.canAdd == true)
    }

    // submit() while canAdd == false is a no-op (no add recorded)
    @Test func submitWhileInvalidIsNoOp() async {
        let client = FakeMenuClient()
        let vm = AddDownloadViewModel(
            initialURL: nil,
            client: client,
            folderPicker: StubFolderPicker())
        vm.urlText = "not-a-url"
        let success = await vm.submit()
        #expect(success == false)
        #expect(client.addedRequests.isEmpty)
    }

    // Add failure: errorText == specific userFacingMessage (assert the string)
    @Test func addFailureSetsErrorTextToUserFacingMessage() async {
        let client = FakeMenuClient()
        let expectedError = GohMenuError.daemonUnavailable("test unavailable")
        client.addError = expectedError
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        let success = await vm.submit()
        #expect(success == false)
        #expect(vm.errorText == expectedError.userFacingMessage)
        // Must not be raw String(describing:) of the error
        #expect(vm.errorText?.contains("daemonUnavailable") == false)
    }

    // Add failure: peerValidation error maps correctly
    @Test func peerValidationErrorMapsToUserFacingMessage() async {
        let client = FakeMenuClient()
        let expectedError = GohMenuError.peerValidation("requirement mismatch")
        client.addError = expectedError
        let vm = AddDownloadViewModel(
            initialURL: "https://example.com/big.iso",
            client: client,
            folderPicker: StubFolderPicker())

        _ = await vm.submit()
        #expect(vm.errorText == expectedError.userFacingMessage)
    }

    // AC4 regression: DO NOT add a hand-built-AddRequest test here — that would be a
    // tautology (it asserts on a value the test itself constructs, never exercising the
    // production one-tap path). The AC4 anchor is the EXISTING, real test in
    // GohMenuViewModelTests.swift: `startsClipboardURLThroughDaemon`, which drives
    // `GohMenuViewModel.performPrimaryAction()` and asserts
    // `client.addedRequests == [AddRequest(url: "https://example.com/big.iso")]`.
    // This task MUST leave that test unchanged and green. If a future edit makes the
    // one-tap path send a destination/connectionCount, THAT test fails — which is the
    // regression signal AC4 requires. No new AC4 test is added in this suite.
}
