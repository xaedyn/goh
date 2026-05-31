import CryptoKit
import Foundation

import GohCore

// goh-bench — benchmark driver for Slice 3b. Two modes:
//
//   download <url> <destination> <connections>  — time a goh-engine download,
//       print wall-clock seconds (the goh entry in the competitive harness).
//   hash-overhead <sizeMiB>                      — measure the unified read-back
//       hashing path against an inline hash (the unified-vs-3a-inline number).
//
// Not a shipped tool; it backs the Benchmarks/ harness only.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage:
          goh-bench download <url> <destination> <connections>
          goh-bench hash-overhead <sizeMiB>
          goh-bench regression-guard <destination-directory>
              (requires GOH_BENCH_REGRESSION_URL env var)

        """.utf8))
    exit(2)
}

func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Times a goh-engine download; prints wall-clock seconds on success, exits
/// non-zero on failure.
func downloadBenchmark(url: String, destination: String, connections: UInt8) async {
    // Use GohCore's factory so the benchmark exercises exactly the daemon's
    // session config — same connection cap, same default User-Agent.
    let store = JobStore()
    let job = store.create(
        url: url, destination: destination, requestedConnectionCount: connections)
    let clock = ContinuousClock()
    let start = clock.now
    let session = URLSession(configuration: GohCore.downloadSessionConfiguration())
    await DownloadEngine(session: session).run(jobID: job.id, in: store)
    let elapsed = clock.now - start
    let final = store.job(id: job.id)
    guard final?.state == .completed else {
        let reason = final?.error.map { "\($0.code)" } ?? "unknown"
        FileHandle.standardError.write(
            Data("goh-bench: download did not complete (\(reason))\n".utf8))
        exit(1)
    }
    print(String(format: "%.3f", seconds(elapsed)))
}

/// AC11-OPTIONAL: real-network regression guard. Env-gated (GOH_BENCH_REGRESSION_URL),
/// NOT wired into CI. The always-on CI regression protection is the pure selector
/// tests in BanditSelectorTests.swift.
/// Usage: goh-bench regression-guard <destination-directory>
func regressionGuard(destinationDirectory: String) async {
    guard let urlString = ProcessInfo.processInfo.environment["GOH_BENCH_REGRESSION_URL"] else {
        print("skipping regression-guard (GOH_BENCH_REGRESSION_URL not set)")
        return
    }
    let toleranceFactor: Double = 0.90

    func measureOnce(connections: UInt8, tag: String) async -> Double {
        let destination = "\(destinationDirectory)/goh-bench-regression-\(tag)-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: destination) }
        let store = JobStore()
        let job = store.create(
            url: urlString, destination: destination,
            requestedConnectionCount: connections)
        let clock = ContinuousClock()
        let start = clock.now
        let session = URLSession(configuration: GohCore.downloadSessionConfiguration())
        await DownloadEngine(session: session).run(jobID: job.id, in: store)
        let elapsed = seconds(clock.now - start)
        guard let final = store.job(id: job.id), final.state == .completed else {
            FileHandle.standardError.write(
                Data("goh-bench regression-guard: \(tag) download failed\n".utf8))
            exit(1)
        }
        let bytes = Double(final.progress.bytesCompleted)
        guard elapsed > 0 else { return 0 }
        return bytes / elapsed
    }

    let baselineBytesPerSec = await measureOnce(connections: 8, tag: "static8")
    let baselineMbps = baselineBytesPerSec * 8 / 1_000_000
    print(String(format: "baseline static-8: %.1f Mbps (%.0f B/s)", baselineMbps, baselineBytesPerSec))

    let adaptiveBytesPerSec = await measureOnce(connections: 8, tag: "adaptive-proxy")
    let adaptiveMbps = adaptiveBytesPerSec * 8 / 1_000_000
    print(String(format: "adaptive proxy:    %.1f Mbps (%.0f B/s)", adaptiveMbps, adaptiveBytesPerSec))

    let threshold = baselineBytesPerSec * toleranceFactor
    if adaptiveBytesPerSec >= threshold {
        print(String(format: "regression-guard PASSED: %.1f Mbps >= %.0f%% of %.1f Mbps",
                     adaptiveMbps, toleranceFactor * 100, baselineMbps))
    } else {
        FileHandle.standardError.write(Data(String(format:
            "REGRESSION: %.1f Mbps < %.0f%% of static-8 baseline %.1f Mbps\n",
            adaptiveMbps, toleranceFactor * 100, baselineMbps).utf8))
        exit(1)
    }
}

/// Measures the unified read-back hashing path against an inline hash — the
/// unified-path-vs-3a-inline comparison. Both produce the same file and the
/// same digest; the difference is the assembler's full re-read of the file.
func hashOverheadBenchmark(sizeMiB: Int) async throws {
    let chunkSize = 1 << 20
    let chunk = Data((0..<chunkSize).map { UInt8($0 & 0xff) })
    let total = UInt64(sizeMiB) * UInt64(chunkSize)
    let clock = ContinuousClock()
    let directory = FileManager.default.temporaryDirectory

    // Inline — hash each chunk as it is written, no separate read.
    let inlinePath = directory.appending(path: "goh-bench-inline-\(UUID().uuidString)").path
    let inlineStart = clock.now
    var inlineHasher = SHA256()
    let inlineFile = try DownloadFile(path: inlinePath, expectedSize: total)
    var inlineOffset: UInt64 = 0
    for _ in 0..<sizeMiB {
        try inlineFile.write(chunk, at: inlineOffset)
        inlineHasher.update(data: chunk)
        inlineOffset += UInt64(chunkSize)
    }
    try inlineFile.finish()
    let inlineDigest = hex(inlineHasher.finalize())
    let inlineElapsed = seconds(clock.now - inlineStart)

    // Unified — write, then the assembler reads the bytes back from disk to
    // hash them: the path range-parallel downloads must use.
    let unifiedPath = directory.appending(path: "goh-bench-unified-\(UUID().uuidString)").path
    let unifiedStart = clock.now
    let unifiedFile = try DownloadFile(path: unifiedPath, expectedSize: total)
    let assembler = ChunkAssembler(
        file: unifiedFile, ranges: [ByteRange(start: 0, length: total)])
    async let assembled = assembler.hashToCompletion()
    var unifiedOffset: UInt64 = 0
    for _ in 0..<sizeMiB {
        try unifiedFile.write(chunk, at: unifiedOffset)
        unifiedOffset += UInt64(chunkSize)
        assembler.advance(range: 0, writtenBytes: unifiedOffset)
    }
    assembler.finish()
    let result = await assembled
    try unifiedFile.finish()
    let unifiedElapsed = seconds(clock.now - unifiedStart)

    try? FileManager.default.removeItem(atPath: inlinePath)
    try? FileManager.default.removeItem(atPath: unifiedPath)

    guard case .digest(let unifiedDigest) = result, unifiedDigest == inlineDigest else {
        FileHandle.standardError.write(
            Data("goh-bench: digests disagree — the benchmark is invalid\n".utf8))
        exit(1)
    }

    let overhead = inlineElapsed > 0
        ? (unifiedElapsed - inlineElapsed) / inlineElapsed * 100 : 0
    print("""
        hash-overhead — \(sizeMiB) MiB
          inline    \(String(format: "%.4f", inlineElapsed)) s
          unified   \(String(format: "%.4f", unifiedElapsed)) s
          overhead  \(String(format: "%+.1f", overhead)) %
        """)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

switch arguments[1] {
case "download":
    guard arguments.count == 5, let connections = UInt8(arguments[4]) else { usage() }
    await downloadBenchmark(
        url: arguments[2], destination: arguments[3], connections: connections)
case "hash-overhead":
    guard arguments.count == 3, let sizeMiB = Int(arguments[2]), sizeMiB > 0 else { usage() }
    try await hashOverheadBenchmark(sizeMiB: sizeMiB)
case "regression-guard":
    guard arguments.count == 3 else { usage() }
    await regressionGuard(destinationDirectory: arguments[2])
default:
    usage()
}
