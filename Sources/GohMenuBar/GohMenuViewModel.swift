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

    private let client: GohMenuClient
    private let presenter: GohMenuPresenter
    private let clipboard: GohClipboardURLDetector
    private let pasteboardText: () -> String?
    private let revealInFinder: (String) -> Void
    private let openTerminalDashboard: () -> Void
    private let copyText: (String) -> Void
    private var snapshots: [ProgressSnapshot] = []
    private var clipboardURL: URL?

    public init(
        client: GohMenuClient,
        presenter: GohMenuPresenter = GohMenuPresenter(),
        clipboard: GohClipboardURLDetector = GohClipboardURLDetector(),
        pasteboardText: @escaping () -> String?,
        revealInFinder: @escaping (String) -> Void,
        openTerminalDashboard: @escaping () -> Void,
        copyText: @escaping (String) -> Void
    ) {
        self.client = client
        self.presenter = presenter
        self.clipboard = clipboard
        self.pasteboardText = pasteboardText
        self.revealInFinder = revealInFinder
        self.openTerminalDashboard = openTerminalDashboard
        self.copyText = copyText
        self.state = presenter.state(
            health: .connecting,
            snapshots: [],
            clipboardURL: nil)
    }

    public func start() {
        let stream = client.progressSnapshots()
        Task { [weak self] in
            do {
                for try await snapshots in stream {
                    self?.applyProgressSnapshots(snapshots)
                }
            } catch {
                self?.applyProgressError(error)
            }
        }
    }

    @discardableResult
    public func consumeOneProgressUpdateForTesting() async -> Bool {
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
            openTerminalDashboard()
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

    private func render(health: GohMenuHealth) {
        state = presenter.state(
            health: health,
            snapshots: snapshots,
            clipboardURL: clipboardURL)
    }

    private func applyProgressSnapshots(_ snapshots: [ProgressSnapshot]) {
        self.snapshots = snapshots
        render(health: .connected)
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
