/// The legal transitions of a job's ``JobState`` (`DESIGN.md` §2.2).
///
/// `completed` and `failed` are terminal — no transition leaves them. There is
/// no `active → queued` transition: running jobs are not preempted, so a running
/// job reaches `queued` only by way of `active → paused → queued`.
public enum JobLifecycle {

    /// A directed transition between two ``JobState`` values.
    public struct Transition: Hashable, Sendable {
        public var from: JobState
        public var to: JobState

        public init(from: JobState, to: JobState) {
            self.from = from
            self.to = to
        }
    }

    /// Every legal `(from, to)` state transition.
    public static let legalTransitions: Set<Transition> = [
        Transition(from: .queued, to: .active),
        Transition(from: .queued, to: .paused),
        Transition(from: .active, to: .paused),
        Transition(from: .active, to: .completed),
        Transition(from: .active, to: .failed),
        Transition(from: .paused, to: .active),
        Transition(from: .paused, to: .queued),
    ]

    /// Whether a job may move directly from `from` to `to`.
    public static func isLegal(from: JobState, to: JobState) -> Bool {
        legalTransitions.contains(Transition(from: from, to: to))
    }
}
