// Tests/GohCoreTests/ChunkQueueTests.swift
import Testing
@testable import GohCore

@Suite("ChunkQueue — interval-set work queue")
struct ChunkQueueTests {

    @Test("pull returns intervals in offset order")
    func pullOrderedIntervals() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 1024 * 1024),
            ByteInterval(start: 1024 * 1024, length: 1024 * 1024),
            ByteInterval(start: 2 * 1024 * 1024, length: 512 * 1024),
        ])
        let first = queue.pull()
        #expect(first?.start == 0)
        let second = queue.pull()
        #expect(second?.start == 1024 * 1024)
        let third = queue.pull()
        #expect(third?.start == 2 * 1024 * 1024)
        let fourth = queue.pull()
        #expect(fourth == nil)
    }

    @Test("returnTail pushes interval back to front")
    func returnTailToFront() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 1024),
            ByteInterval(start: 1024, length: 1024),
        ])
        let first = queue.pull()!
        queue.returnToFront(first)
        let re = queue.pull()!
        #expect(re.start == 0)
    }

    @Test("remainingBytes decrements on pull, not on complete")
    func remainingBytesTracking() {
        let total: UInt64 = 3 * 1024 * 1024
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: total),
        ])
        #expect(queue.remainingBytes == total)
        let chunk = queue.pull()!
        #expect(queue.remainingBytes == 0)
        queue.markDone(chunk)
        #expect(queue.remainingBytes == 0)
    }

    @Test("isDone when all intervals completed")
    func isDoneCondition() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
        ])
        let a = queue.pull()!
        let b = queue.pull()!
        #expect(!queue.isDone)
        queue.markDone(a)
        #expect(!queue.isDone)
        queue.markDone(b)
        #expect(queue.isDone)
    }

    @Test("intervals from a ByteRange map 1:1")
    func missingRangesCompatibility() {
        let range = ByteRange(start: 512 * 1024, length: 1024 * 1024)
        let interval = ByteInterval(from: range)
        #expect(interval.start == range.start)
        #expect(interval.length == range.length)
    }

    // MARK: — Exhaustive state-machine transitions

    @Test("mixed states — pending, in-flight, and done coexist")
    func mixedStateTransitions() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
            ByteInterval(start: 200, length: 100),
        ])
        // Pull two (both in-flight); one stays pending.
        let a = queue.pull()!          // start 0  → in-flight
        let b = queue.pull()!          // start 100 → in-flight
        #expect(queue.remainingBytes == 100)   // only start-200 still pending
        queue.markDone(a)              // start 0 → done; b still in-flight
        #expect(!queue.isDone)         // start-100 in-flight, start-200 pending
        // Complete the rest.
        let c = queue.pull()!          // start 200 → in-flight
        queue.markDone(b)
        queue.markDone(c)
        #expect(queue.isDone)
        #expect(queue.remainingBytes == 0)
    }

    @Test("all pulled but none marked done — not isDone")
    func allPulledNoneDone() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
        ])
        _ = queue.pull()
        _ = queue.pull()
        #expect(queue.pull() == nil)   // nothing left pending
        #expect(queue.remainingBytes == 0)
        #expect(!queue.isDone)         // both in-flight, neither done
    }

    @Test("empty queue is trivially done")
    func emptyQueueInit() {
        let queue = ChunkQueue(intervals: [])
        #expect(queue.pull() == nil)
        #expect(queue.remainingBytes == 0)
        #expect(queue.isDone)
    }

    @Test("pull → returnToFront → pull returns the same interval, ahead of others")
    func pullReturnPullRoundTrip() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
        ])
        let first = queue.pull()!            // start 0
        #expect(first.start == 0)
        queue.returnToFront(first)           // back to front, no longer in-flight
        #expect(queue.remainingBytes == 200) // both pending again
        let again = queue.pull()!
        #expect(again.start == 0)            // same interval returned, ahead of start-100
        let next = queue.pull()!
        #expect(next.start == 100)
        #expect(!queue.isDone)
    }
}
