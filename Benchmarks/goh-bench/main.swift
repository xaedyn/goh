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
          goh-bench lfn [--url <url>] [--runs <n>] [--static-n <n>] [--output <file>]
              (SM5a/SM2: governed vs static-N; median + IQR seconds as JSON)

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
    let assembler = ChunkAssembler(file: unifiedFile, totalBytes: total)
    async let assembled = assembler.hashToCompletion()
    var unifiedOffset: UInt64 = 0
    for _ in 0..<sizeMiB {
        let writeStart = unifiedOffset
        try unifiedFile.write(chunk, at: writeStart)
        unifiedOffset += UInt64(chunkSize)
        assembler.complete(interval: ByteInterval(start: writeStart, length: UInt64(chunkSize)))
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

// MARK: — lfn (SM5a/SM2): governed vs static-N over a long-fat-network target.

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Linear-interpolated inter-quartile range (Q3 − Q1).
func iqr(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard s.count >= 2 else { return 0 }
    func quantile(_ p: Double) -> Double {
        let idx = p * Double(s.count - 1)
        let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
        if lo == hi { return s[lo] }
        let frac = idx - Double(lo)
        return s[lo] * (1 - frac) + s[hi] * frac
    }
    return quantile(0.75) - quantile(0.25)
}

/// Runs `runs` downloads of `url`, governed (staticN == nil) or pinned to a static N
/// (staticN != nil → the engine's explicit-connection-count channel disables the governor),
/// and prints a JSON line with median + IQR wall-clock seconds. Real network; not in CI.
func lfnBenchmark(url: String, runs: Int, staticN: UInt8?, output: String?) async {
    let mode = staticN.map { "static-\($0)" } ?? "governed"
    var times: [Double] = []
    for run in 1...runs {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "goh-bench-lfn-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: destination) }
        let store = JobStore()
        // requestedConnectionCount seeds N₀ (the governor refines it live; static-N pins it).
        let job = store.create(
            url: url, destination: destination, requestedConnectionCount: staticN ?? 8)
        let session = URLSession(configuration: GohCore.downloadSessionConfiguration())
        let clock = ContinuousClock()
        let start = clock.now
        // staticN != nil → explicitConnectionCount disables the governor (the control arm).
        await DownloadEngine(session: session).run(
            jobID: job.id, in: store, explicitConnectionCount: staticN)
        let elapsed = seconds(clock.now - start)
        guard let final = store.job(id: job.id), final.state == .completed else {
            let reason = store.job(id: job.id)?.error.map { "\($0.code)" } ?? "unknown"
            FileHandle.standardError.write(
                Data("goh-bench lfn: run \(run)/\(runs) (\(mode)) did not complete (\(reason))\n".utf8))
            exit(1)
        }
        times.append(elapsed)
        FileHandle.standardError.write(
            Data("  run \(run)/\(runs) (\(mode)): \(String(format: "%.3f", elapsed)) s\n".utf8))
    }
    let med = median(times)
    let spread = iqr(times)
    let allSeconds = times.map { String(format: "%.3f", $0) }.joined(separator: ",")
    let json = "{\"url\":\"\(url)\",\"mode\":\"\(mode)\",\"runs\":\(runs),"
        + "\"medianSeconds\":\(String(format: "%.3f", med)),"
        + "\"iqrSeconds\":\(String(format: "%.3f", spread)),"
        + "\"allSeconds\":[\(allSeconds)]}"
    print(json)
    if let output {
        do { try json.write(toFile: output, atomically: true, encoding: .utf8) }
        catch {
            FileHandle.standardError.write(
                Data("goh-bench lfn: could not write \(output): \(error)\n".utf8))
            exit(1)
        }
    }
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
case "lfn":
    var url = "https://sin-speed.hetzner.com/1GB.bin"
    var runs = 5
    var staticN: UInt8?
    var output: String?
    var i = 2
    while i < arguments.count {
        switch arguments[i] {
        case "--url":
            i += 1; guard i < arguments.count else { usage() }; url = arguments[i]
        case "--runs":
            i += 1; guard i < arguments.count, let r = Int(arguments[i]), r > 0 else { usage() }
            runs = r
        case "--static-n":
            i += 1; guard i < arguments.count, let n = UInt8(arguments[i]), n > 0 else { usage() }
            staticN = n
        case "--output":
            i += 1; guard i < arguments.count else { usage() }; output = arguments[i]
        default:
            usage()
        }
        i += 1
    }
    await lfnBenchmark(url: url, runs: runs, staticN: staticN, output: output)
default:
    usage()
}
