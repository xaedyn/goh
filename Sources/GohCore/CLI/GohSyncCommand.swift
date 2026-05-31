import Darwin
import Foundation

/// `goh sync` — the trust-core keystone (spec §9.1).
///
/// Reads a `gohfile.toml`, downloads every missing or changed asset through the
/// daemon, verifies each against its pin (or records it trust-on-first-use), and
/// writes a self-contained `gohfile.lock`. Idempotent: a second run with no
/// changes performs zero transfers.
///
/// Exit codes (frozen §9):
///   0  — success (all present and verified, or nothing to sync)
///   1  — transport failure (could not reach gohd)
///   2  — checksumMismatch (a pinned asset's bytes did not match after download)
///   3  — TOFU drift (an unpinned asset's hash changed, no --accept-changed)
///   5  — path confinement refused (an asset path escaped base)
///   7  — lock busy (another goh sync/verify holds the advisory lock)
///   8  — download failed (failed/disappeared/timed-out job)
///   64 — usage error (bad manifest, bad arguments, missing manifest)
///
/// Precedence among failures: 5 > 2 > 3 > 8 (1 only for transport).
public enum GohSyncCommand {

    // MARK: - Entry point

    public static func run(
        manifestPath: String,
        base: String?,
        acceptChanged: Bool,
        send: @escaping GohCommandLine.Sender,
        watchdogSeconds: TimeInterval = 120
    ) -> GohCommandLineResult {
        var output = ""

        // ── Step 1: read + parse the manifest (bad/missing → 64) ─────────────
        let manifestText: String
        do {
            manifestText = try String(contentsOfFile: manifestPath, encoding: .utf8)
        } catch {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "goh sync: cannot read manifest at \(manifestPath)\n")
        }

        let manifest: ManifestCodec.ManifestFile
        do {
            manifest = try ManifestCodec.parse(manifestText)
        } catch let e as ManifestCodec.CodecError {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "goh sync: invalid manifest: \(e.message)\n")
        } catch {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "goh sync: invalid manifest: \(error)\n")
        }

        // ── Step 2: resolve + canonicalize the base directory ────────────────
        let manifestDir = URL(fileURLWithPath: manifestPath)
            .deletingLastPathComponent()
        let resolvedBase = resolveBase(
            cliBase: base, manifestBase: manifest.base, manifestDir: manifestDir)

        // ── Step 3: advisory flock on the stable sidecar lock ────────────────
        // The advisory lock is held on `gohfile.lock.lock`, a sidecar that is
        // NEVER renamed/replaced — unlike `gohfile.lock` itself, which
        // `writeLockAtomically` swaps via rename(2). Holding the flock on the
        // data file would be broken: the rename installs a new inode, so a
        // concurrent sync/verify would open that new inode and acquire its own
        // independent lock. The sidecar inode is stable for the whole run, so
        // sync's LOCK_EX and verify's LOCK_SH truly contend (spec §9, exit 7).
        let lockPath = manifestDir.appendingPathComponent("gohfile.lock").path
        let sidecarPath = manifestDir.appendingPathComponent(TrustLockSidecar.name).path
        let lockFD = open(sidecarPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: "goh sync: cannot open lock file at \(sidecarPath)\n")
        }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            return GohCommandLineResult(
                exitCode: 7,
                standardError: "goh sync: another goh sync/verify is running on this lock\n")
        }

        // ── Step 4: load any prior lock, decide authoritativeness ────────────
        let priorLock = loadPriorLock(at: lockPath, currentManifestHash: manifest.manifestHash)
        var priorEntries: [String: LockfileCodec.LockEntry] = [:]
        if let priorLock {
            for entry in priorLock.entries { priorEntries[entry.path] = entry }
        }

        // ── Empty manifest: write a zero-entry lock, exit 0 ──────────────────
        if manifest.assets.isEmpty {
            output += "nothing to sync\n"
            do {
                try writeLockAtomically(
                    LockfileCodec.Lockfile(manifestHash: manifest.manifestHash, entries: []),
                    to: lockPath)
            } catch {
                return GohCommandLineResult(
                    exitCode: 64,
                    standardError: "goh sync: failed to write lock: \(error)\n")
            }
            return GohCommandLineResult(exitCode: 0, standardOutput: output)
        }

        // ── Step 5: per-entry loop ───────────────────────────────────────────
        var acceptedEntries: [LockfileCodec.LockEntry] = []
        var worstExit: Int32 = 0
        let detector = CompletionDetector(send: send, watchdogSeconds: watchdogSeconds)

        for asset in manifest.assets {
            let outcome = process(
                asset: asset,
                base: resolvedBase,
                priorEntry: priorEntries[asset.path],
                acceptChanged: acceptChanged,
                send: send,
                detector: detector)
            output += outcome.log
            worstExit = combine(worstExit, outcome.exitContribution)
            if let entry = outcome.entry {
                acceptedEntries.append(entry)
            }
        }

        // ── Step 6: write the lock atomically ────────────────────────────────
        do {
            try writeLockAtomically(
                LockfileCodec.Lockfile(
                    manifestHash: manifest.manifestHash, entries: acceptedEntries),
                to: lockPath)
        } catch {
            return GohCommandLineResult(
                exitCode: 64,
                standardError: output + "goh sync: failed to write lock: \(error)\n")
        }

        return GohCommandLineResult(exitCode: worstExit, standardOutput: output)
    }

    // MARK: - Per-entry processing

    /// The result of processing one `[[asset]]`.
    private struct EntryOutcome {
        var log: String
        var exitContribution: Int32
        /// The lock entry to write, or nil to drop the entry.
        var entry: LockfileCodec.LockEntry?
    }

    private static func process(
        asset: ManifestCodec.AssetEntry,
        base: String,
        priorEntry: LockfileCodec.LockEntry?,
        acceptChanged: Bool,
        send: @escaping GohCommandLine.Sender,
        detector: CompletionDetector
    ) -> EntryOutcome {
        // Confinement pre-flight (exit-contribution 5).
        let dest: String
        do {
            dest = try SyncPathConfinement.resolve(entryPath: asset.path, base: base)
        } catch let e as SyncPathConfinement.ConfinementError {
            return EntryOutcome(
                log: "FAILED \(asset.path): \(e.message)\n",
                exitContribution: 5, entry: nil)
        } catch {
            return EntryOutcome(
                log: "FAILED \(asset.path): path confinement error: \(error)\n",
                exitContribution: 5, entry: nil)
        }

        let fileExists = FileManager.default.fileExists(atPath: dest)

        if fileExists, let onDisk = try? FileDigest.sha256WithSize(path: dest) {
            // ── File already present: classify against pin / prior lock ──────
            if let pin = asset.sha256 {
                // Pinned: a match means up to date; otherwise fall through to
                // re-download (digest matches neither pin nor lock).
                if onDisk.0 == pin {
                    return upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
                }
            } else {
                // Unpinned.
                if let prior = priorEntry {
                    if onDisk.0 == prior.sha256 {
                        return upToDate(asset: asset, digest: onDisk.0, size: onDisk.1)
                    }
                    // A smaller file is an interrupted partial → re-download.
                    if onDisk.1 >= prior.size {
                        // Complete-but-changed unpinned entry → AC5 (T6.4).
                        return tofuChange(
                            asset: asset, prior: prior, onDisk: onDisk,
                            acceptChanged: acceptChanged)
                    }
                    // else: partial — fall through to download.
                } else {
                    // Present, unpinned, no prior lock entry → trust on first use.
                    return firstUse(asset: asset, digest: onDisk.0, size: onDisk.1)
                }
            }
        }

        // ── Download path ────────────────────────────────────────────────────
        let addRequest = AddRequest(url: asset.url, destination: dest)
        let job: JobSummary
        do {
            job = try sendAdd(addRequest, send: send)
        } catch {
            return EntryOutcome(
                log: "FAILED \(asset.path): could not reach gohd (\(error))\n",
                exitContribution: 1, entry: nil)
        }

        // Poll to completion (T6.3).
        switch detector.awaitCompletion(jobID: job.id) {
        case .completed:
            break
        case .failed(let contribution, let message):
            return EntryOutcome(
                log: "FAILED \(asset.path): \(message)\n",
                exitContribution: contribution, entry: nil)
        case .transport(let message):
            return EntryOutcome(
                log: "FAILED \(asset.path): \(message)\n",
                exitContribution: 1, entry: nil)
        }

        // Re-hash the bytes at dest (digest is ALWAYS recomputed CLI-side).
        guard let downloaded = try? FileDigest.sha256WithSize(path: dest) else {
            return EntryOutcome(
                log: "FAILED \(asset.path): downloaded file unreadable\n",
                exitContribution: 8, entry: nil)
        }

        if let pin = asset.sha256, asset.verify {
            if downloaded.0 == pin {
                return EntryOutcome(
                    log: "downloaded \(asset.path)\n",
                    exitContribution: 0,
                    entry: makeEntry(asset: asset, digest: downloaded.0, size: downloaded.1))
            }
            // Pinned mismatch after download → quarantine + exit 2.
            quarantine(path: dest)
            return EntryOutcome(
                log: "FAILED \(asset.path): checksum mismatch (expected \(pin), got \(downloaded.0)); quarantined\n",
                exitContribution: 2, entry: nil)
        }

        // Unpinned (or verify=false): record trust-on-first-use.
        return EntryOutcome(
            log: "recorded \(asset.path) \(downloaded.0) (first use, unverified)\n",
            exitContribution: 0,
            entry: makeEntry(asset: asset, digest: downloaded.0, size: downloaded.1))
    }

    // MARK: - Outcome builders

    private static func upToDate(
        asset: ManifestCodec.AssetEntry, digest: String, size: Int
    ) -> EntryOutcome {
        EntryOutcome(
            log: "up to date \(asset.path)\n",
            exitContribution: 0,
            entry: makeEntry(asset: asset, digest: digest, size: size))
    }

    private static func firstUse(
        asset: ManifestCodec.AssetEntry, digest: String, size: Int
    ) -> EntryOutcome {
        EntryOutcome(
            log: "recorded \(asset.path) \(digest) (first use, unverified)\n",
            exitContribution: 0,
            entry: makeEntry(asset: asset, digest: digest, size: size))
    }

    /// AC5: an unpinned entry whose complete on-disk bytes differ from the
    /// recorded lock hash (T6.4).
    private static func tofuChange(
        asset: ManifestCodec.AssetEntry,
        prior: LockfileCodec.LockEntry,
        onDisk: (String, Int),
        acceptChanged: Bool
    ) -> EntryOutcome {
        // verify == false suppresses drift enforcement: accept the new bytes
        // silently (no exit-3 event).
        if !asset.verify {
            return EntryOutcome(
                log: "up to date \(asset.path)\n",
                exitContribution: 0,
                entry: makeEntry(asset: asset, digest: onDisk.0, size: onDisk.1))
        }

        let event = "hash changed for unpinned entry \(asset.path): \(prior.sha256) → \(onDisk.0)\n"
        if acceptChanged {
            return EntryOutcome(
                log: event,
                exitContribution: 0,
                entry: makeEntry(asset: asset, digest: onDisk.0, size: onDisk.1))
        }
        // Without --accept-changed: keep the OLD entry, contribute exit 3.
        return EntryOutcome(log: event, exitContribution: 3, entry: prior)
    }

    private static func makeEntry(
        asset: ManifestCodec.AssetEntry, digest: String, size: Int
    ) -> LockfileCodec.LockEntry {
        LockfileCodec.LockEntry(
            url: asset.url,
            path: asset.path,
            sha256: digest,
            size: size,
            downloadedAt: iso8601Now())
    }

    // MARK: - Daemon I/O

    private static func sendAdd(
        _ request: AddRequest, send: @escaping GohCommandLine.Sender
    ) throws -> JobSummary {
        let client = GohCommandClient(send: send)
        return try client.send(.add(request: request), expecting: JobSummary.self)
    }

    // MARK: - Base resolution

    private static func resolveBase(
        cliBase: String?, manifestBase: String?, manifestDir: URL
    ) -> String {
        let raw: String
        if let cliBase {
            // CLI --base: cwd-relative, expand a leading ~.
            raw = expandTilde(cliBase)
        } else if let manifestBase {
            // Manifest base (spec §7.4): expand only a leading `~`/`~/` (never
            // `$VAR`). An expanded or already-absolute result is used as-is; a
            // still-relative result stays relative to the manifest's directory.
            let expanded = expandTilde(manifestBase)
            if expanded.hasPrefix("/") {
                raw = expanded
            } else {
                raw = manifestDir.appendingPathComponent(expanded).path
            }
        } else {
            raw = manifestDir.path
        }
        let absolute: String
        if raw.hasPrefix("/") {
            absolute = raw
        } else {
            absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(raw).path
        }
        return URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
    }

    private static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        return home + String(path.dropFirst(1))
    }

    // MARK: - Prior lock loading

    private static func loadPriorLock(
        at lockPath: String, currentManifestHash: String
    ) -> LockfileCodec.Lockfile? {
        guard let toml = try? String(contentsOfFile: lockPath, encoding: .utf8) else {
            return nil
        }
        guard let lock = try? LockfileCodec.decode(toml) else {
            // Corrupt / unknown version → rebuild (sync's job is to regenerate).
            return nil
        }
        // A lock for a different manifest is not authoritative for "up to date".
        guard lock.manifestHash == currentManifestHash else {
            return nil
        }
        return lock
    }

    // MARK: - Exit precedence (5 > 2 > 3 > 8 > 1)

    private static func combine(_ current: Int32, _ candidate: Int32) -> Int32 {
        rank(candidate) > rank(current) ? candidate : current
    }

    private static func rank(_ code: Int32) -> Int {
        switch code {
        case 0: return 0
        case 1: return 1   // transport, lowest real failure
        case 8: return 2
        case 3: return 3
        case 2: return 4
        case 5: return 5
        default: return 1
        }
    }

    // MARK: - Quarantine

    private static func quarantine(path: String) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let target = path + ".corrupt-\(timestamp)"
        try? FileManager.default.moveItem(atPath: path, toPath: target)
    }

    // MARK: - Atomic lock write (T6.5)

    /// Writes `lock` to `lockPath` atomically: write a `.tmp` sibling, fsync it,
    /// `rename(2)` it into place, then fsync the directory. The destination is
    /// never observed half-written. Cleans up the `.tmp` file on failure.
    static func writeLockAtomically(
        _ lock: LockfileCodec.Lockfile, to lockPath: String
    ) throws {
        let toml = LockfileCodec.encode(lock)
        let tmpPath = lockPath + ".tmp"
        let dirPath = URL(fileURLWithPath: lockPath).deletingLastPathComponent().path

        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw LockWriteError.cannotOpen(tmpPath)
        }
        do {
            let bytes = Array(toml.utf8)
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let n = Darwin.write(fd, base + written, bytes.count - written)
                    if n < 0 { throw LockWriteError.writeFailed(tmpPath) }
                    written += n
                }
            }
            if fsync(fd) != 0 { throw LockWriteError.fsyncFailed(tmpPath) }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw error
        }
        close(fd)

        if rename(tmpPath, lockPath) != 0 {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw LockWriteError.renameFailed(tmpPath)
        }

        // fsync the directory so the rename is durable.
        let dirFD = open(dirPath, O_RDONLY | O_CLOEXEC)
        if dirFD >= 0 {
            fsync(dirFD)
            close(dirFD)
        }
    }

    enum LockWriteError: Error, Equatable {
        case cannotOpen(String)
        case writeFailed(String)
        case fsyncFailed(String)
        case renameFailed(String)
    }

    // MARK: - Time

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
