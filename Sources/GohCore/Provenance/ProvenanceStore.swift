import Darwin
import Foundation
import Synchronization

/// A failure writing the provenance ledger to disk.
public enum ProvenanceStoreError: Error {
    case fsyncOpenFailed(path: String, errno: Int32)
    case fsyncFailed(path: String, errno: Int32)
    case renameFailed(errno: Int32)
}

/// The outcome of loading the provenance ledger.
public struct ProvenanceLoadResult: Sendable {
    /// The loaded record — empty when the file was missing or unreadable.
    public var record: ProvenanceRecord
    /// When the on-disk file was unreadable, the path the bytes were **copied** to
    /// before recovery; `nil` on a clean or first-run load.
    ///
    /// The corrupt original is LEFT IN PLACE — `recoverToEmpty()` uses `copyItem`,
    /// not `moveItem`. The next `record(entry:)` call overwrites it via atomic rename.
    public var corruptionSidecar: URL?
}

/// Reads, writes, and maintains the in-memory provenance ledger.
///
/// Concurrency: all mutable state is guarded by a `Mutex`. The daemon is the
/// SOLE WRITER; the CLI is a read-only consumer via direct file reads.
///
/// Saves are atomic and durable — identical pattern to `HostProfileStore`
/// (temp→`chmod 0600`→`fsync(tmp)`→`rename(2)`→`fsync(dir)`). The file is
/// written at owner-only 0600 permissions.
///
/// INTENTIONALLY NO TTL EVICTION — unlike `HostProfileStore` which TTL-evicts at
/// 90 days. Evicting provenance entries would silently lose the user's own record
/// of where their files came from and what their hashes were. If a future maintainer
/// is copying the `HostProfileStore` idiom here, do NOT add TTL eviction.
public final class ProvenanceStore: Sendable {

    private let fileURL: URL
    private let inner: Mutex<Inner>

    private struct Inner: Sendable {
        var record: ProvenanceRecord
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.inner = Mutex(Inner(record: .empty))
    }

    // MARK: — Load

    /// Loads the provenance ledger from disk. Call once at daemon startup.
    ///
    /// On corrupt or version-mismatch: **copies** the on-disk file to a
    /// `.corrupt-<unixtime>` sidecar (the original is left in place), resets
    /// in-memory state to `.empty`, and returns the sidecar URL in the result.
    /// The next `record(entry:)` overwrites the corrupt original via atomic rename.
    @discardableResult
    public func load() -> ProvenanceLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            inner.withLock { $0.record = .empty }
            return ProvenanceLoadResult(record: .empty, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let record = try PropertyListDecoder().decode(ProvenanceRecord.self, from: data)
            guard record.version == ProvenanceRecord.currentVersion else {
                return recoverToEmpty()
            }
            inner.withLock { $0.record = record }
            return ProvenanceLoadResult(record: record, corruptionSidecar: nil)
        } catch {
            return recoverToEmpty()
        }
    }

    /// READ-ONLY load for the CLI consumers (`goh which`, `goh verify --all`).
    ///
    /// BLOCK-3: the CLI is a read-only consumer — it must NOT create the support
    /// directory, write a `.corrupt-<ts>` sidecar, or reset the on-disk store
    /// (only the daemon's `load()` performs recovery). On a missing, unreadable, or
    /// version-mismatched file this returns `false` and leaves in-memory state empty;
    /// on a clean decode it populates in-memory state and returns `true`. No side
    /// effects on disk in any case.
    ///
    /// `goh which` ignores the `Bool` (a non-match `lookup` is indistinguishable from
    /// "no store" — both fall through silently). `goh verify --all` does NOT use this
    /// method; it reads the file directly so it can distinguish corrupt (exit 6) from
    /// empty (exit 0) — see Task 7.
    @discardableResult
    public func loadReadOnly() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let record = try? PropertyListDecoder().decode(ProvenanceRecord.self, from: data),
              record.version == ProvenanceRecord.currentVersion
        else {
            inner.withLock { $0.record = .empty }
            return false
        }
        inner.withLock { $0.record = record }
        return true
    }

    // MARK: — Write

    /// Updates or appends an entry for `entry.destinationPath` and atomically
    /// rewrites the store.
    ///
    /// **In-place keyed by `destinationPath`**: if an entry with the same canonical
    /// `destinationPath` string already exists, it is replaced; otherwise the
    /// entry is appended. The path is already canonical (callers must apply
    /// `URL(fileURLWithPath:).standardizedFileURL.path` before constructing the entry).
    ///
    /// The full rewrite is O(n) in the number of recorded entries. At personal scale
    /// (thousands to tens-of-thousands of downloads), this is imperceptible — see
    /// Approach A "THE BET" in the approach decision memo.
    public func record(entry: ProvenanceEntry) throws {
        try inner.withLock { inner in
            if let idx = inner.record.entries.firstIndex(where: {
                $0.destinationPath == entry.destinationPath
            }) {
                inner.record.entries[idx] = entry
            } else {
                inner.record.entries.append(entry)
            }
            try writeAtomically(&inner.record)
        }
    }

    /// Merges a batch of sync-verified entries into the ledger in a single
    /// `Mutex.withLock` + one atomic write (O(n) total — not O(n²) per-entry).
    ///
    /// Merge rule (§3.2): same canonical path + same sha256 → preserve `downloadedAt`,
    /// set `verifiedAt`, refresh `url`/`size`; otherwise (new path OR sha changed) →
    /// new entry with `downloadedAt = verifiedAt` AND `verifiedAt = verifiedAt`.
    /// The entry's `sha256` is stored verbatim (already `"sha256:"`-prefixed; never re-prefix).
    /// Empty `entries` is a no-op (no lock acquired, no disk write).
    public func recordVerified(entries: [VerifiedProvenanceEntry]) throws {
        guard !entries.isEmpty else { return }
        try inner.withLock { inner in
            for entry in entries {
                let canonical = URL(fileURLWithPath: entry.destinationPath).standardizedFileURL.path

                // All-or-nothing baseline (B2): baseline is present iff ALL FIVE fields are non-nil.
                let hasBaseline = entry.recordedStatSize != nil
                    && entry.recordedMtimeSeconds != nil
                    && entry.recordedMtimeNanoseconds != nil
                    && entry.recordedInode != nil
                    && entry.recordedDevice != nil

                if let idx = inner.record.entries.firstIndex(where: { $0.destinationPath == canonical }) {
                    let existing = inner.record.entries[idx]
                    if existing.sha256 == entry.sha256 {
                        // Same path + same sha256 (primary backfill path: re-verifying pre-#104 entry).
                        // Preserve downloadedAt; refresh verifiedAt, url, size.
                        inner.record.entries[idx].verifiedAt = entry.verifiedAt
                        inner.record.entries[idx].url = entry.url
                        inner.record.entries[idx].size = entry.size
                        // OVERWRITE stat fields when incoming baseline present; leave existing when absent.
                        if hasBaseline {
                            inner.record.entries[idx].recordedStatSize = entry.recordedStatSize
                            inner.record.entries[idx].recordedMtimeSeconds = entry.recordedMtimeSeconds
                            inner.record.entries[idx].recordedMtimeNanoseconds = entry.recordedMtimeNanoseconds
                            inner.record.entries[idx].recordedInode = entry.recordedInode
                            inner.record.entries[idx].recordedDevice = entry.recordedDevice
                        }
                        // If !hasBaseline: leave existing stat fields untouched (don't null them).
                    } else {
                        // Same path + different sha256: treat as new file (downloadedAt = verifiedAt).
                        inner.record.entries[idx] = ProvenanceEntry(
                            url: entry.url, sha256: entry.sha256, size: entry.size,
                            downloadedAt: entry.verifiedAt, destinationPath: canonical,
                            verifiedAt: entry.verifiedAt,
                            recordedStatSize: hasBaseline ? entry.recordedStatSize : nil,
                            recordedMtimeSeconds: hasBaseline ? entry.recordedMtimeSeconds : nil,
                            recordedMtimeNanoseconds: hasBaseline ? entry.recordedMtimeNanoseconds : nil,
                            recordedInode: hasBaseline ? entry.recordedInode : nil,
                            recordedDevice: hasBaseline ? entry.recordedDevice : nil)
                    }
                } else {
                    // Brand-new path — downloadedAt = verifiedAt.
                    inner.record.entries.append(ProvenanceEntry(
                        url: entry.url, sha256: entry.sha256, size: entry.size,
                        downloadedAt: entry.verifiedAt, destinationPath: canonical,
                        verifiedAt: entry.verifiedAt,
                        recordedStatSize: hasBaseline ? entry.recordedStatSize : nil,
                        recordedMtimeSeconds: hasBaseline ? entry.recordedMtimeSeconds : nil,
                        recordedMtimeNanoseconds: hasBaseline ? entry.recordedMtimeNanoseconds : nil,
                        recordedInode: hasBaseline ? entry.recordedInode : nil,
                        recordedDevice: hasBaseline ? entry.recordedDevice : nil))
                }
            }
            try writeAtomically(&inner.record)
        }
    }

    // MARK: — Read

    /// Returns the entry whose stored `destinationPath` matches the canonical form
    /// of `destinationPath`, or `nil` if not found.
    ///
    /// Canonicalization is applied internally (ADVISORY C): callers pass the raw
    /// user-supplied path; this method applies
    /// `URL(fileURLWithPath:).standardizedFileURL.path` once and string-compares
    /// against the already-canonical stored keys. Neither the caller nor any other
    /// reader re-normalizes stored keys.
    public func lookup(destinationPath: String) -> ProvenanceEntry? {
        let canonical = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        return inner.withLock { inner in
            inner.record.entries.first { $0.destinationPath == canonical }
        }
    }

    /// Returns a snapshot of all entries (for `goh verify --all`).
    public func allEntries() -> [ProvenanceEntry] {
        inner.withLock { $0.record.entries }
    }

    // MARK: — Delete

    /// Removes every entry whose canonical `destinationPath` matches one of `paths`,
    /// then atomically rewrites the ledger. Empty `paths` is a no-op (no lock, no
    /// write). A path matching no entry is silently skipped (idempotent).
    ///
    /// INVARIANT (security): this method mutates `record.entries[]` ONLY. It MUST
    /// NEVER unlink, truncate, or modify any file at any of `paths`. The only
    /// filesystem writes are `writeAtomically`'s own temp/target/dir operations.
    ///
    /// Each input path is canonicalized via
    /// `URL(fileURLWithPath:).standardizedFileURL.path` before matching, exactly
    /// as `recordVerified` / `lookup` do — stored keys are already canonical.
    ///
    /// Returns the number of entries actually removed. Throws on `writeAtomically`
    /// failure (the dispatcher turns that into a failure reply — not a best-effort .ack).
    @discardableResult
    public func forget(paths: [String]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let canonical = Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        return try inner.withLock { inner in
            let before = inner.record.entries.count
            inner.record.entries.removeAll { canonical.contains($0.destinationPath) }
            let removed = before - inner.record.entries.count
            // Only write when something actually changed — avoids a needless atomic
            // rewrite (and fsync) when no requested path matched.
            if removed != 0 {
                try writeAtomically(&inner.record)
            }
            return removed
        }
    }

    // MARK: — Private helpers

    private func recoverToEmpty() -> ProvenanceLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: fileURL, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        inner.withLock { $0.record = .empty }
        return ProvenanceLoadResult(
            record: .empty,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    private func writeAtomically(_ record: inout ProvenanceRecord) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)

        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw ProvenanceStoreError.renameFailed(errno: errno)
            }
            try Self.fsync(path: directory.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fsync(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ProvenanceStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ProvenanceStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
