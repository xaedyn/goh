import Foundation
import Testing

import GohCore

@Suite("Command dispatcher")
struct CommandDispatcherTests {

    @Test("add creates a queued job and replies with its summary")
    func addCreatesJob() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/f.iso")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job, got \(outcome)")
            return
        }
        #expect(summary.id == 1)
        #expect(summary.state == .queued)
        #expect(summary.url == "https://example.com/f.iso")
    }

    @Test("add without a destination derives one from the URL")
    func addDerivesDestination() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let outcome = dispatcher.reply(
            to: .add(request: AddRequest(url: "https://example.com/big.iso")))
        guard case .job(let summary) = outcome else {
            Issue.record("expected .job, got \(outcome)")
            return
        }
        #expect(summary.destination.hasSuffix("big.iso"))
    }

    @Test("add honours an explicit destination and connection count")
    func addHonoursExplicitFields() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let request = AddRequest(url: "u", destination: "/tmp/x", connectionCount: 4)
        guard case .job(let summary) = dispatcher.reply(to: .add(request: request)) else {
            Issue.record("expected .job")
            return
        }
        #expect(summary.destination == "/tmp/x")
        #expect(summary.requestedConnectionCount == 4)
    }

    @Test("ls replies with every job in creation order")
    func lsListsJobs() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u1")))
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u2")))
        guard case .list(let reply) = dispatcher.reply(to: .ls) else {
            Issue.record("expected .list")
            return
        }
        #expect(reply.jobs.map(\.id) == [1, 2])
    }

    @Test("pause then resume move a job through paused and back to queued")
    func pauseThenResume() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))
        guard case .job(let paused) = dispatcher.reply(to: .pause(jobID: 1)) else {
            Issue.record("expected .job from pause")
            return
        }
        #expect(paused.state == .paused)
        guard case .job(let resumed) = dispatcher.reply(to: .resume(jobID: 1)) else {
            Issue.record("expected .job from resume")
            return
        }
        #expect(resumed.state == .queued)
    }

    @Test("rm removes a job and replies with the removed id")
    func rmRemovesJob() {
        let dispatcher = CommandDispatcher(store: JobStore())
        _ = dispatcher.reply(to: .add(request: AddRequest(url: "u")))
        guard case .removed(let reply) = dispatcher.reply(to: .rm(request: RmRequest(jobID: 1)))
        else {
            Issue.record("expected .removed")
            return
        }
        #expect(reply.removedJobID == 1)
        guard case .list(let after) = dispatcher.reply(to: .ls) else {
            Issue.record("expected .list")
            return
        }
        #expect(after.jobs.isEmpty)
    }

    @Test("pause, resume, and rm of an unknown id reply with a jobNotFound failure")
    func unknownIdFails() {
        let dispatcher = CommandDispatcher(store: JobStore())
        let commands: [Command] = [
            .pause(jobID: 9), .resume(jobID: 9), .rm(request: RmRequest(jobID: 9)),
        ]
        for command in commands {
            guard case .failure(let error) = dispatcher.reply(to: command) else {
                Issue.record("expected .failure for \(command)")
                return
            }
            #expect(error.code == .jobNotFound)
        }
    }
}
