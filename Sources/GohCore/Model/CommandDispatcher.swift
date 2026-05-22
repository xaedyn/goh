import Foundation

/// Routes a decoded ``Command`` to the ``JobStore`` and produces a
/// ``CommandOutcome`` (`DESIGN.md` §3).
///
/// The dispatcher is pure with respect to the wire — it neither decodes the
/// request envelope nor encodes the reply; the XPC adapter does that and
/// translates the outcome into a `reply`- or `error`-kind envelope.
public struct CommandDispatcher: Sendable {

    /// The frozen default connection count when `add` omits it (`DESIGN.md` §4).
    /// The §3.1 valid-range clamp/reject is deferred to the engine slice, where
    /// the count becomes operative.
    public static let defaultConnectionCount: UInt8 = 8

    private let store: JobStore
    private let onJobQueued: (@Sendable (UInt64) -> Void)?

    /// Creates a dispatcher over `store`. `onJobQueued`, when provided, is called
    /// with a job's id whenever a command leaves that job `queued` — after
    /// `add`, and after a `resume` that returns a job to `queued` — so the
    /// daemon can hand it to the download engine.
    public init(
        store: JobStore,
        onJobQueued: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.store = store
        self.onJobQueued = onJobQueued
    }

    /// Handles `command`, mutating the job store, and returns the outcome.
    public func reply(to command: Command) -> CommandOutcome {
        do {
            switch command {
            case .add(let request):
                let job = store.create(
                    url: request.url,
                    destination: request.destination
                        ?? Self.defaultDestination(forURL: request.url),
                    requestedConnectionCount: request.connectionCount
                        ?? Self.defaultConnectionCount)
                onJobQueued?(job.id)
                return .job(job)

            case .ls:
                return .list(LsReply(jobs: store.allJobs()))

            case .pause(let jobID):
                return .job(try store.pause(id: jobID))

            case .resume(let jobID):
                let summary = try store.resume(id: jobID)
                if summary.state == .queued {
                    onJobQueued?(jobID)
                }
                return .job(summary)

            case .rm(let request):
                try store.remove(id: request.jobID)
                return .removed(RmReply(removedJobID: request.jobID))
            }
        } catch let error as GohError {
            return .failure(error)
        } catch {
            // The store throws only `GohError`; this is an unreachable guard.
            return .failure(GohError(code: .cancelled, message: "\(error)"))
        }
    }

    /// Derives a destination when `add` omits one — the URL's last path
    /// component in the user's Downloads directory.
    static func defaultDestination(forURL url: String) -> String {
        let lastComponent = URL(string: url)?.lastPathComponent ?? ""
        let filename = lastComponent.isEmpty ? "download" : lastComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads")
            .appending(path: filename)
            .path
    }
}
