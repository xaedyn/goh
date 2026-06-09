import Foundation

/// The reason a file's fast metadata check concluded the file has changed.
///
/// Precedence (highest to lowest): identity > size > mtime.
/// The most fundamental change is reported when multiple fields differ.
public enum FastChangeReason: Sendable, Equatable {
    /// The inode/device pair changed — the path now refers to a different object
    /// (replaced, cloned, or restored with a new inode). Also fires when the path
    /// is no longer a regular file (symlink/dir/device).
    case identity
    /// The file size changed.
    case size
    /// The modification time changed (tv_sec or tv_nsec).
    case mtime
}

/// The result of a fast metadata check for one file.
public enum FastCheckStatus: Sendable, Equatable {
    /// All five baseline fields (size, mtime, inode, device) match exactly.
    /// HEURISTIC — not a cryptographic proof. `looksUnchanged` in the presenter.
    case unchanged
    /// At least one field differs. See `FastChangeReason` for which.
    case changed(FastChangeReason)
    /// `lstat` returned `ENOENT` — the file is missing.
    case missing
    /// `lstat` failed with a non-ENOENT errno (e.g. EACCES, ELOOP, ENOTDIR).
    /// A present-but-unreadable file is never reported `.missing`.
    case indeterminate
    /// The `ProvenanceEntry` does not have a complete baseline (one or more of the
    /// five fields is nil). Fast-check cannot run — not an alert state.
    case notBaselined
}

/// Pure, probe-injectable fast-check logic. No real I/O; no `Date()`.
///
/// Thread-safe: all methods are static and pure.
public enum FastCheckRunner {

    /// Checks one entry against the current filesystem state.
    ///
    /// Comparison order (precedence high→low): incomplete baseline → notBaselined;
    /// probe result → missing/indeterminate; isRegularFile → identity;
    /// (inode, device) → identity; size → size; (mtimeSec, mtimeNsec) → mtime;
    /// else → unchanged.
    public static func check(
        _ entry: ProvenanceEntry,
        probe: any FileStatProbing
    ) -> FastCheckStatus {
        // AC6: all five fields must be non-nil for a valid baseline.
        guard
            let recordedSize   = entry.recordedStatSize,
            let mtimeSec       = entry.recordedMtimeSeconds,
            let mtimeNsec      = entry.recordedMtimeNanoseconds,
            let recordedInode  = entry.recordedInode,
            let recordedDevice = entry.recordedDevice
        else {
            return .notBaselined
        }

        switch probe.probe(path: entry.destinationPath) {
        case .notFound:
            return .missing                    // AC4

        case .unreadable:
            return .indeterminate              // AC5

        case .stat(let current):
            // AC7: non-regular file → identity change.
            guard current.isRegularFile else {
                return .changed(.identity)
            }
            // AC3 precedence: identity > size > mtime.
            if current.inode != recordedInode || current.device != recordedDevice {
                return .changed(.identity)
            }
            if current.size != recordedSize {
                return .changed(.size)
            }
            if current.mtimeSeconds != mtimeSec || current.mtimeNanoseconds != mtimeNsec {
                return .changed(.mtime)
            }
            return .unchanged                  // AC2
        }
    }

    /// Checks all entries, returning results in INPUT order, 1:1.
    ///
    /// Each entry generates exactly one `probe.probe(path:)` call — no content reads.
    public static func checkAll(
        _ entries: [ProvenanceEntry],
        probe: any FileStatProbing
    ) -> [(ProvenanceEntry, FastCheckStatus)] {
        entries.map { entry in (entry, check(entry, probe: probe)) }
    }
}
