import Darwin
import Foundation

/// CLI-local integrity verifier for `goh verify`.
///
/// Re-hashes each entry in `gohfile.lock` against the file on disk and reports
/// OK / FAILED / MISSING. No daemon or XPC connection required.
///
/// Exit code contract (frozen §9.4):
///   0  — all entries OK (and, under --strict-untracked, none untracked)
///   2  — at least one checksumMismatch
///   6  — lock missing, corrupt (quarantined), unknown lockfileVersion, or stale manifestHash
///   7  — could not acquire advisory shared lock (another goh holds it)
///   9  — at least one locked entry's file is MISSING on disk
///   10 — --strict-untracked: untracked files present, no MISSING or FAILED
///
/// Precedence among outcomes: 9 > 2 > 10.
public enum GohVerifyCommand {

    /// Runs `goh verify` and returns a result suitable for the CLI runner.
    ///
    /// - Parameters:
    ///   - lockPath: Path to `gohfile.lock` (may be relative or absolute).
    ///   - strictUntracked: When `true`, untracked files under the lock directory
    ///     contribute exit code 10.
    public static func run(lockPath: String, strictUntracked: Bool) -> GohCommandLineResult {
        let lockURL = URL(fileURLWithPath: lockPath)

        // ── Step 1: Load and decode the lockfile ──────────────────────────────

        guard let toml = try? String(contentsOf: lockURL, encoding: .utf8) else {
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "no gohfile.lock; run goh sync first\n")
        }

        let lockfile: LockfileCodec.Lockfile
        do {
            lockfile = try LockfileCodec.decode(toml)
        } catch let e as LockfileCodec.CodecError {
            // Distinguish unknown-version (don't quarantine) from corrupt (quarantine).
            if e.message.hasPrefix("unsupported lockfileVersion") {
                return GohCommandLineResult(
                    exitCode: 6,
                    standardOutput: "\(e.message)\n")
            }
            // Corrupt / unparseable — quarantine the lock file.
            quarantine(lockURL: lockURL)
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "corrupt lockfile\n")
        } catch {
            quarantine(lockURL: lockURL)
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "corrupt lockfile\n")
        }

        // ── Step 2: Acquire a shared advisory lock (LOCK_SH | LOCK_NB) ───────

        let fd = open(lockPath, O_RDONLY)
        guard fd >= 0 else {
            return GohCommandLineResult(
                exitCode: 6,
                standardOutput: "could not open lockfile\n")
        }
        defer { close(fd) }

        let flockResult = flock(fd, LOCK_SH | LOCK_NB)
        if flockResult != 0 {
            return GohCommandLineResult(
                exitCode: 7,
                standardOutput: "another goh sync/verify is running on this lockfile\n")
        }
        defer { flock(fd, LOCK_UN) }

        // ── Step 3: Check manifestHash against a co-located gohfile.toml ─────

        let lockDir = lockURL.deletingLastPathComponent()
        let tomlURL = lockDir.appendingPathComponent("gohfile.toml")
        if let tomlText = try? String(contentsOf: tomlURL, encoding: .utf8) {
            if let manifest = try? ManifestCodec.parse(tomlText) {
                if manifest.manifestHash != lockfile.manifestHash {
                    return GohCommandLineResult(
                        exitCode: 6,
                        standardOutput: "lock is stale (manifestHash mismatch); run goh sync\n")
                }
            }
        }

        // ── Step 4: Verify each entry ─────────────────────────────────────────

        if lockfile.entries.isEmpty {
            return GohCommandLineResult(
                exitCode: 0,
                standardOutput: "0 entries, all verified\n")
        }

        var lines: [String] = []
        var hasMissing = false
        var hasFailed = false
        var lockedPaths: Set<String> = []

        for entry in lockfile.entries {
            // Defensive: reject absolute paths or parent-escaping traversal.
            guard !entry.path.hasPrefix("/"), !entry.path.contains("../") else {
                lines.append("FAILED \(entry.path) (unsafe path in lockfile entry)\n")
                hasFailed = true
                continue
            }

            // §9.3a: resolve relative to the lock's directory, not cwd.
            let fileURL = lockDir.appendingPathComponent(entry.path)
            let filePath = fileURL.path

            // Track for untracked enumeration (normalize the path).
            lockedPaths.insert(fileURL.standardizedFileURL.path)

            let result: (hash: String, byteCount: Int)?
            do {
                let (hash, byteCount) = try FileDigest.sha256WithSize(path: filePath)
                result = (hash, byteCount)
            } catch FileDigest.DigestError.cannotOpen {
                lines.append("MISSING \(entry.path) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            } catch {
                lines.append("MISSING \(entry.path) (expected \(entry.sha256))\n")
                hasMissing = true
                continue
            }

            if result!.hash == entry.sha256 {
                lines.append("OK \(entry.path)\n")
            } else {
                lines.append(
                    "FAILED \(entry.path) expected \(entry.sha256) actual \(result!.hash)\n")
                hasFailed = true
            }
        }

        // ── Step 5: --strict-untracked enumeration ─────────────────────────────

        var hasUntracked = false
        if strictUntracked || !hasMissing && !hasFailed {
            // Walk the lock directory and flag regular files not in the lock.
            let skipNames: Set<String> = ["gohfile.lock", "gohfile.toml"]
            if let enumerator = FileManager.default.enumerator(
                at: lockDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let itemURL as URL in enumerator {
                    let name = itemURL.lastPathComponent
                    // Skip lock/toml files and quarantined lock copies.
                    if skipNames.contains(name) || name.hasPrefix("gohfile.lock.corrupt-") {
                        continue
                    }
                    // Only flag regular files (not directories).
                    let isRegular =
                        (try? itemURL.resourceValues(forKeys: [.isRegularFileKey])
                            .isRegularFile) == true
                    guard isRegular else { continue }

                    let stdPath = itemURL.standardizedFileURL.path
                    if !lockedPaths.contains(stdPath) {
                        // Compute path relative to lockDir for display.
                        let displayPath: String
                        let lockDirPath = lockDir.standardizedFileURL.path
                        if stdPath.hasPrefix(lockDirPath + "/") {
                            displayPath = String(stdPath.dropFirst(lockDirPath.count + 1))
                        } else {
                            displayPath = stdPath
                        }
                        lines.append("untracked \(displayPath)\n")
                        if strictUntracked {
                            hasUntracked = true
                        }
                    }
                }
            }
        }

        // ── Step 6: Determine exit code per precedence ────────────────────────

        let output = lines.joined()
        let exitCode: Int32
        if hasMissing {
            exitCode = 9
        } else if hasFailed {
            exitCode = 2
        } else if strictUntracked && hasUntracked {
            exitCode = 10
        } else {
            exitCode = 0
        }

        return GohCommandLineResult(exitCode: exitCode, standardOutput: output)
    }

    // MARK: - Private helpers

    /// Renames `gohfile.lock` to `gohfile.lock.corrupt-<unixtime>` for recovery.
    private static func quarantine(lockURL: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let quarantineURL = lockURL.deletingLastPathComponent()
            .appendingPathComponent("gohfile.lock.corrupt-\(timestamp)")
        try? FileManager.default.moveItem(at: lockURL, to: quarantineURL)
    }
}
