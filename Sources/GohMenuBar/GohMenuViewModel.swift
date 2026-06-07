import Combine
import Foundation
import GohCore

@MainActor
public protocol GohMenuClient: AnyObject {
    func progressSnapshots() -> AsyncThrowingStream<[ProgressSnapshot], any Error>
    func add(_ request: AddRequest) async throws -> JobSummary
    func pause(jobID: UInt64) async throws
    func resume(jobID: UInt64) async throws
    func remove(jobID: UInt64, keepPartialFile: Bool) async throws
}

@MainActor
public final class GohMenuViewModel: ObservableObject {
    @Published public private(set) var state: GohMenuState
    @Published public private(set) var trustOverview: GohTrustOverview = .empty

    private let client: GohMenuClient
    private let presenter: GohMenuPresenter
    private let clipboard: GohClipboardURLDetector
    private let pasteboardText: () -> String?
    private let revealInFinder: (String) -> Void
    private let openTerminalDashboard: () -> Void
    private let openDoctorCommand: () -> Void
    private let copyText: (String) -> Void
    private var snapshots: [ProgressSnapshot] = []
    private var clipboardURL: URL?
    private var progressTask: Task<Void, Never>?
    private let trustReader: (any ProvenanceReading)?
    /// Called synchronously at the end of every `applyProgressSnapshots` call (seed first, then
    /// updates). Set this BEFORE calling `start()` so the seed delivery is captured. Plain closure
    /// — no @Published / Combine — to prevent a replay of the initial `[]` that would defeat seed
    /// suppression in GohNotificationCoordinator.
    public var onProgressSnapshots: (([ProgressSnapshot]) -> Void)?

    public init(
        client: GohMenuClient,
        presenter: GohMenuPresenter = GohMenuPresenter(),
        clipboard: GohClipboardURLDetector = GohClipboardURLDetector(),
        pasteboardText: @escaping () -> String?,
        revealInFinder: @escaping (String) -> Void,
        openTerminalDashboard: @escaping () -> Void,
        openDoctor: @escaping () -> Void = {},
        copyText: @escaping (String) -> Void,
        trustReader: (any ProvenanceReading)? = nil
    ) {
        self.client = client
        self.presenter = presenter
        self.clipboard = clipboard
        self.pasteboardText = pasteboardText
        self.revealInFinder = revealInFinder
        self.openTerminalDashboard = openTerminalDashboard
        self.openDoctorCommand = openDoctor
        self.copyText = copyText
        self.trustReader = trustReader
        self.state = presenter.state(
            health: .connecting,
            snapshots: [],
            clipboardURL: nil)
    }

    deinit {
        progressTask?.cancel()
    }

    public func start() {
        stop()
        let stream = client.progressSnapshots()
        progressTask = Task { [weak self] in
            do {
                for try await snapshots in stream {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.applyProgressSnapshots(snapshots)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.applyProgressError(error)
            }
        }
        Task { await loadTrustOverview() }
    }

    public func loadTrustOverview() async {
        guard let reader = trustReader else { return }
        let outcome = await Task.detached(priority: .utility) { reader.read() }.value
        trustOverview = GohTrustPresenter().present(outcome).0
    }

    @discardableResult
    func consumeOneProgressUpdateForTesting() async -> Bool {
        do {
            for try await next in client.progressSnapshots() {
                applyProgressSnapshots(next)
                return true
            }
            return false
        } catch {
            applyProgressError(error)
            return false
        }
    }

    public func stop() {
        progressTask?.cancel()
        progressTask = nil
    }

    public func refreshClipboard() async {
        clipboardURL = clipboard.url(from: pasteboardText())
        render(health: state.health)
    }

    public func performPrimaryAction() async {
        switch state.primaryAction {
        case .addClipboardURL(let url):
            do {
                _ = try await client.add(AddRequest(url: url.absoluteString))
            } catch {
                render(health: .failed(menuError(from: error)))
            }
        case .pasteURL:
            await refreshClipboard()
        case .diagnose:
            openDoctorCommand()
        }
    }

    public func pause(jobID: UInt64) async {
        do {
            try await client.pause(jobID: jobID)
        } catch {
            render(health: .failed(menuError(from: error)))
        }
    }

    public func resume(jobID: UInt64) async {
        do {
            try await client.resume(jobID: jobID)
        } catch {
            render(health: .failed(menuError(from: error)))
        }
    }

    public func remove(jobID: UInt64, keepPartialFile: Bool) async {
        do {
            try await client.remove(jobID: jobID, keepPartialFile: keepPartialFile)
        } catch {
            render(health: .failed(menuError(from: error)))
        }
    }

    public func reveal(destination: String) {
        revealInFinder(destination)
    }

    public func copy(_ text: String) {
        copyText(text)
    }

    public func openTop() {
        openTerminalDashboard()
    }

    public func openDoctor() {
        openDoctorCommand()
    }

    /// Factory that creates an AddDownloadViewModel without exposing the private client.
    /// Pre-fills the URL field with the currently-detected clipboard URL if any.
    public func makeAddDownloadViewModel(
        folderPicker: any FolderPicker
    ) -> AddDownloadViewModel {
        AddDownloadViewModel(
            initialURL: clipboardURL?.absoluteString,
            client: client,
            folderPicker: folderPicker)
    }

    private func render(health: GohMenuHealth) {
        state = presenter.state(
            health: health,
            snapshots: snapshots,
            clipboardURL: clipboardURL)
    }

    private func applyProgressSnapshots(_ snapshots: [ProgressSnapshot]) {
        self.snapshots = snapshots
        render(health: .connected)
        onProgressSnapshots?(snapshots)   // seed is the first call; hook must be set before start()
    }

    private func applyProgressError(_ error: any Error) {
        render(health: .failed(menuError(from: error)))
    }

    private func menuError(from error: any Error) -> GohMenuError {
        if let error = error as? GohMenuError {
            return error
        }

        if let error = error as? GohCommandClientError {
            switch error {
            case .daemon(let daemonError):
                if daemonError.code == .protocolVersionMismatch {
                    return .protocolMismatch(daemonError.message ?? daemonError.code.rawValue)
                }
                return .daemon(daemonError)
            case .malformedReply(let detail):
                return .malformedReply(detail)
            }
        }

        return .daemonUnavailable(String(describing: error))
    }
}
