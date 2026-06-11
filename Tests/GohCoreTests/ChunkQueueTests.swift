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

    @Test("intervals are sorted by start on init regardless of input order")
    func pullSortsUnorderedInput() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 2 * 1024 * 1024, length: 512 * 1024),
            ByteInterval(start: 0, length: 1024 * 1024),
            ByteInterval(start: 1024 * 1024, length: 1024 * 1024),
        ])
        #expect(queue.pull()?.start == 0)
        #expect(queue.pull()?.start == 1024 * 1024)
        #expect(queue.pull()?.start == 2 * 1024 * 1024)
    }

    @Test("returnToFront pushes interval back to front")
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

    @Test("intervals from a ByteRange map 1:1")
    func missingRangesCompatibility() {
        let range = ByteRange(start: 512 * 1024, length: 1024 * 1024)
        let interval = ByteInterval(from: range)
        #expect(interval.start == range.start)
        #expect(interval.length == range.length)
    }

    @Test("empty queue yields nil on pull")
    func emptyQueueInit() {
        let queue = ChunkQueue(intervals: [])
        #expect(queue.pull() == nil)
    }

    @Test("pull → returnToFront → pull returns the same interval, ahead of others")
    func pullReturnPullRoundTrip() {
        let queue = ChunkQueue(intervals: [
            ByteInterval(start: 0, length: 100),
            ByteInterval(start: 100, length: 100),
        ])
        let first = queue.pull()!            // start 0
        #expect(first.start == 0)
        queue.returnToFront(first)           // back to front
        let again = queue.pull()!
        #expect(again.start == 0)            // same interval returned, ahead of start-100
        let next = queue.pull()!
        #expect(next.start == 100)
        #expect(queue.pull() == nil)
    }
}
