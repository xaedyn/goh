import Testing

import GohCore

@Suite("Job lifecycle transitions")
struct JobLifecycleTests {

    /// Asserts that exactly the `legal` targets are permitted out of `from`, and
    /// every other `JobState` is rejected — an exhaustive walk of `from`'s row.
    private func check(from: JobState, legal: Set<JobState>) {
        for to in JobState.allCases {
            let permitted = JobLifecycle.isLegal(from: from, to: to)
            if legal.contains(to) {
                #expect(permitted, "\(from) → \(to) should be legal")
            } else {
                #expect(!permitted, "\(from) → \(to) should be rejected")
            }
        }
    }

    @Test("a queued job starts or is paused before it starts — nothing else")
    func fromQueued() {
        check(from: .queued, legal: [.active, .paused])
    }

    @Test("an active job pauses, completes, or fails — never preempted to queued")
    func fromActive() {
        check(from: .active, legal: [.paused, .completed, .failed])
    }

    @Test("a paused job resumes to active or back to queued — nothing else")
    func fromPaused() {
        check(from: .paused, legal: [.active, .queued])
    }

    @Test("completed is terminal — no transition leaves it")
    func fromCompleted() {
        check(from: .completed, legal: [])
    }

    @Test("failed is terminal — no transition leaves it")
    func fromFailed() {
        check(from: .failed, legal: [])
    }
}
