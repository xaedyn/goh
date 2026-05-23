import Testing

import GohCore

@Suite("Byte-range splitting")
struct ByteRangeTests {

    /// Checks the ranges are contiguous from 0 and cover exactly `total`.
    private func contiguousCovering(_ ranges: [ByteRange], total: UInt64) -> Bool {
        var next: UInt64 = 0
        for range in ranges {
            if range.start != next { return false }
            next += range.length
        }
        return next == total
    }

    @Test("a large total splits into the requested number of contiguous ranges")
    func splitsIntoRequestedRanges() {
        let ranges = ByteRange.split(total: 8 << 20, requested: 8, minChunk: 1 << 20)
        #expect(ranges.count == 8)
        #expect(ranges.allSatisfy { $0.length == 1 << 20 })
        #expect(contiguousCovering(ranges, total: 8 << 20))
    }

    @Test("the connection count is capped so no range falls below the minimum chunk")
    func capsByMinimumChunk() {
        let ranges = ByteRange.split(total: 3 << 20, requested: 8, minChunk: 1 << 20)
        #expect(ranges.count == 3)
        #expect(contiguousCovering(ranges, total: 3 << 20))
    }

    @Test("a total below the minimum chunk yields a single range")
    func smallTotalIsOneRange() {
        let ranges = ByteRange.split(total: 500_000, requested: 8, minChunk: 1 << 20)
        #expect(ranges == [ByteRange(start: 0, length: 500_000)])
    }

    @Test("an uneven split gives the remainder to the last range")
    func remainderGoesToLastRange() {
        let ranges = ByteRange.split(total: 10, requested: 3, minChunk: 1)
        #expect(ranges == [
            ByteRange(start: 0, length: 3),
            ByteRange(start: 3, length: 3),
            ByteRange(start: 6, length: 4),
        ])
    }
}
