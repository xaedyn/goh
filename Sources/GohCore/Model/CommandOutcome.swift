/// The result of dispatching a ``Command`` (`DESIGN.md` §3).
///
/// A success carries the command's reply payload; a failure carries a
/// ``GohError``. On the wire the reply envelope's `messageType` — `reply` versus
/// `error` — discriminates the two branches.
public enum CommandOutcome: Sendable, Equatable {
    /// `add` / `pause` / `resume` — the resulting job summary.
    case job(JobSummary)
    /// `ls` — the job list.
    case list(LsReply)
    /// `rm` — the removed job's id.
    case removed(RmReply)
    /// `authImportSafari` — the number of imported cookies.
    case authImported(AuthImportSafariReply)
    /// `recordVerifiedProvenance` — zero-payload acknowledgement.
    case ack
    /// Any command — a structured failure.
    case failure(GohError)
}
