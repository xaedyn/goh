import Darwin
import Foundation
import Testing
import GohCore

@Suite("FileDigest.sha256WithSizeAndStat")
struct FileDigestStatTests {

    // AC4: fstat on the open handle describes the hashed inode.
    // Compare digest's FileStat to an independent lstat of the unchanged file.
    // A valid open fd always produces a non-nil stat; the failure→nil path is
    // defensive (no external test can force fstat to fail on a valid open fd)
    // and is covered by code inspection / the guard in the implementation.
    @Test("AC4: captured FileStat matches independent lstat of hashed file")
    func capturedStatMatchesLstat() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("hello backfill\n".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)

        // A real file's fstat always succeeds on a valid open fd.
        let s = try #require(result.stat, "fstat must succeed on a valid open fd")

        // Independent lstat of the same path.
        var st = stat()
        let rc = tmp.path.withCString { Darwin.lstat($0, &st) }
        #expect(rc == 0)

        #expect(s.size == Int64(st.st_size))
        #expect(s.mtimeSeconds == Int64(st.st_mtimespec.tv_sec))
        #expect(s.inode == UInt64(st.st_ino))
        #expect(s.isRegularFile == true)
    }

    // AC10: recordedStatSize source is stat.size, not hashedByteCount.
    // For a normal file they are equal; assert the named field source explicitly
    // by checking the FileStat.size field (the one that feeds recordedStatSize).
    @Test("AC10: stat.size field matches fstat st_size (source for recordedStatSize)")
    func statSizeEqualsFstatStSize() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let content = Data(repeating: 0xAB, count: 1024)
        try content.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)

        // A real file's fstat always succeeds on a valid open fd.
        let s = try #require(result.stat, "fstat must succeed on a valid open fd")

        var st = stat()
        let rc = tmp.path.withCString { Darwin.lstat($0, &st) }
        #expect(rc == 0)
        // stat.size is the fstat st_size — the source for recordedStatSize.
        #expect(s.size == Int64(st.st_size))
        // hashedByteCount is the streaming byte count — separate field.
        #expect(result.size == content.count)
        // For a normal regular file they are equal; the fields are distinct.
        #expect(s.size == Int64(result.size))
    }

    // isRegularFile derives from (st_mode & S_IFMT) == S_IFREG (NOT S_ISREG macro).
    @Test("isRegularFile true for a regular temp file")
    func isRegularFileTrue() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("data".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)
        // A real file's fstat always succeeds on a valid open fd.
        let s = try #require(result.stat)
        #expect(s.isRegularFile == true)
    }

    // Missing file still throws cannotOpen (same as sha256WithSize).
    @Test("throws cannotOpen for nonexistent file")
    func throwsForMissing() {
        #expect(throws: FileDigest.DigestError.cannotOpen("/nonexistent/backfill-test")) {
            _ = try FileDigest.sha256WithSizeAndStat(path: "/nonexistent/backfill-test")
        }
    }

    // Hash is consistent with sha256WithSize for the same file.
    @Test("sha256 matches sha256WithSize output for same file")
    func hashMatchesSha256WithSize() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("consistency check".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (baseHash, _) = try FileDigest.sha256WithSize(path: tmp.path)
        let result = try FileDigest.sha256WithSizeAndStat(path: tmp.path)
        #expect(result.sha256 == baseHash)
    }
}
