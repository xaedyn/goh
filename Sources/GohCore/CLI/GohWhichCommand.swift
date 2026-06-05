import Darwin
import Foundation

/// CLI-local provenance lookup for `goh which <path>`.
///
/// Checks two sources in order:
/// 1. `gohfile.lock` — lock-entry path matched against the target file.
/// 2. Spotlight extended attributes — `kMDItemWhereFroms` / `kMDItemDownloadedDate`.
///
/// No daemon or XPC connection is required.
public enum GohWhichCommand {

    /// Runs `goh which` and returns a result suitable for the CLI runner.
    ///
    /// - Parameters:
    ///   - filePath: Absolute (or relative to cwd) path of the file to look up.
    ///   - lockPath: Path to `gohfile.lock`; may be absent or unreadable without error.
    ///   - provenanceStorePath: Path to `provenance.plist`; `nil` (the default) skips
    ///     the ledger branch entirely, preserving today's lock→xattr→exit-4 behavior.
    ///     The real CLI call site passes the resolved `ProvenanceStoreLocation` path;
    ///     existing tests that omit this parameter are unaffected.
    public static func run(
        filePath: String,
        lockPath: String,
        provenanceStorePath: String? = nil
    ) -> GohCommandLineResult {
        let targetURL = URL(fileURLWithPath: filePath).standardizedFileURL

        // 1. Lock lookup (unchanged).
        if let output = lookupInLock(targetURL: targetURL, lockPath: lockPath) {
            return GohCommandLineResult(exitCode: 0, standardOutput: output)
        }

        // 2. NEW: Provenance-ledger lookup (skipped when provenanceStorePath is nil).
        if let storePath = provenanceStorePath,
           let output = lookupInLedger(targetURL: targetURL, storePath: storePath) {
            return GohCommandLineResult(exitCode: 0, standardOutput: output)
        }

        // 3. xattr fallback (unchanged).
        if let output = lookupInXattr(path: filePath) {
            return GohCommandLineResult(exitCode: 0, standardOutput: output)
        }

        // 4. Neither source has it.
        return GohCommandLineResult(
            exitCode: 4,
            standardOutput: "no provenance record for \(filePath)\n")
    }

    // MARK: - Ledger lookup

    /// Looks up the target in `provenance.plist` at `storePath`, via the SHARED
    /// `ProvenanceStore.lookup(destinationPath:)` (BLOCK-3 — one canonicalization+compare,
    /// the same path the unit tests exercise). Returns formatted output on match, or `nil`
    /// on no-match, missing file, version mismatch, or decode error.
    ///
    /// READ-ONLY: `loadReadOnly()` never creates the store directory or a `.corrupt`
    /// sidecar — recovery is the daemon's job alone. A missing/unreadable/corrupt store
    /// is indistinguishable from "no match" here; both fall through silently (the `which`
    /// contract has no corrupt-ledger exit code — that distinction is `verify --all`'s job).
    private static func lookupInLedger(targetURL: URL, storePath: String) -> String? {
        let store = ProvenanceStore(fileURL: URL(fileURLWithPath: storePath))
        // false → missing / unreadable / version-mismatch: no match, no side effects.
        guard store.loadReadOnly() else { return nil }

        // Pass the raw target path; ProvenanceStore.lookup canonicalizes internally
        // (the ONE shared canonicalization — §5.3). `targetURL.path` is the raw path
        // the CLI received (already absolute via URL(fileURLWithPath:)).
        guard let entry = store.lookup(destinationPath: targetURL.path) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        var out = "url:          \(entry.url)\n"
        out    += "sha256:       \(entry.sha256)\n"
        out    += "downloadedAt: \(formatter.string(from: entry.downloadedAt))\n"
        return out
    }

    // MARK: - Lock lookup

    private static func lookupInLock(targetURL: URL, lockPath: String) -> String? {
        let lockFileURL = URL(fileURLWithPath: lockPath)

        guard let toml = try? String(contentsOf: lockFileURL, encoding: .utf8) else {
            // Missing or unreadable lock — fall through silently.
            return nil
        }

        guard let lockfile = try? LockfileCodec.decode(toml) else {
            // Malformed lock — fall through silently (not fatal for `which`).
            return nil
        }

        // §9.3a: resolve each entry's path relative to the directory containing
        // the lock file, NOT the process cwd.
        let lockDir = lockFileURL.deletingLastPathComponent()

        for entry in lockfile.entries {
            let entryURL = lockDir
                .appendingPathComponent(entry.path)
                .standardizedFileURL

            if entryURL == targetURL {
                var out = "url:          \(entry.url)\n"
                out    += "sha256:       \(entry.sha256)\n"
                out    += "downloadedAt: \(entry.downloadedAt)\n"
                return out
            }
        }

        return nil
    }

    // MARK: - xattr fallback

    private static func lookupInXattr(path: String) -> String? {
        guard let whereFroms = readWhereFroms(path: path), let url = whereFroms.first else {
            return nil
        }

        let downloadedDate = readDownloadedDate(path: path)

        var out = "url:          \(url)\n"
        out    += "sha256:       (not recorded)\n"
        if let date = downloadedDate {
            let formatted = ISO8601DateFormatter().string(from: date)
            out += "downloadedAt: \(formatted)\n"
        }
        return out
    }

    /// Reads `com.apple.metadata:kMDItemWhereFroms` from the file's extended attributes.
    ///
    /// Returns the array of where-from URL strings, or `nil` if the attribute is absent
    /// or cannot be decoded.
    private static func readWhereFroms(path: String) -> [String]? {
        return readXattrPropertyList(
            path: path,
            name: SpotlightMetadataTagger.whereFromsAttributeName
        ) as? [String]
    }

    /// Reads `com.apple.metadata:kMDItemDownloadedDate` from the file's extended attributes.
    ///
    /// Returns the `Date`, or `nil` if the attribute is absent or cannot be decoded.
    /// The tagger writes a bare `Date` (not wrapped in an array).
    private static func readDownloadedDate(path: String) -> Date? {
        return readXattrPropertyList(
            path: path,
            name: SpotlightMetadataTagger.downloadedDateAttributeName
        ) as? Date
    }

    /// Generic xattr → binary plist → `Any` reader.
    private static func readXattrPropertyList(path: String, name: String) -> Any? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &bytes, bytes.count, 0, 0)
        guard read == length else { return nil }

        return try? PropertyListSerialization.propertyList(
            from: Data(bytes),
            options: [],
            format: nil)
    }
}
