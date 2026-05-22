import Darwin
import Foundation

/// A failure writing the job catalog to disk.
public enum CatalogStoreError: Error {
    /// `open` failed while fsyncing a path.
    case fsyncOpenFailed(path: String, errno: Int32)
    /// `fsync` failed.
    case fsyncFailed(path: String, errno: Int32)
    /// `rename` of the temporary file over the target failed.
    case renameFailed(errno: Int32)
}

/// The outcome of loading the job catalog.
public struct CatalogLoadResult: Sendable {
    /// The loaded catalog — an empty catalog when the file was missing or
    /// unreadable.
    public var catalog: JobCatalog
    /// When the on-disk catalog was unreadable, the path its bytes were copied
    /// to before recovery; `nil` on a clean (or first-run) load.
    public var corruptionSidecar: URL?
}

/// Reads and writes the daemon's job catalog (`DESIGN.md` §2).
///
/// **Saves are atomic and durable.** The catalog is encoded as a binary property
/// list, written to a temporary file in the *same directory* as the target,
/// fsynced, renamed over the target with `rename(2)`, and then the directory is
/// fsynced. Same-directory is required — `rename(2)` is atomic only within one
/// filesystem; `rename(2)` rather than `renamex_np(RENAME_SWAP)` because this
/// replaces the target, it does not swap two live files. fsyncing both the file
/// and the directory makes the replacement survive a crash, not merely a clean
/// exit.
///
/// **An unreadable catalog recovers to empty** — see ``load()``.
public struct CatalogStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Atomically and durably writes `catalog` to disk.
    public func save(_ catalog: JobCatalog) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(catalog)

        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            try Self.fsync(path: temporaryURL.path)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw CatalogStoreError.renameFailed(errno: errno)
            }
            try Self.fsync(path: directory.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Loads the catalog, recovering to an empty catalog when the file is
    /// missing or unreadable.
    ///
    /// A missing file is a clean first run. An unreadable file — corrupt bytes,
    /// or a schema version the daemon does not understand — is copied to a
    /// `.corrupt-<timestamp>` sidecar (so it can be investigated) and the daemon
    /// starts with an empty catalog rather than refusing to start.
    public func load() -> CatalogLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CatalogLoadResult(catalog: .empty, corruptionSidecar: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let catalog = try PropertyListDecoder().decode(JobCatalog.self, from: data)
            // Only version 1 exists today; a future version's load path migrates
            // here. A version the daemon does not understand is unreadable.
            guard catalog.version == JobCatalog.currentVersion else {
                return recoverToEmpty()
            }
            return CatalogLoadResult(catalog: catalog, corruptionSidecar: nil)
        } catch {
            return recoverToEmpty()
        }
    }

    /// Copies the unreadable catalog to a timestamped sidecar and returns an
    /// empty catalog.
    private func recoverToEmpty() -> CatalogLoadResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let sidecar = fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        try? FileManager.default.copyItem(at: fileURL, to: sidecar)
        let sidecarExists = FileManager.default.fileExists(atPath: sidecar.path)
        return CatalogLoadResult(
            catalog: .empty,
            corruptionSidecar: sidecarExists ? sidecar : nil)
    }

    /// fsyncs the file or directory at `path`.
    private static func fsync(path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CatalogStoreError.fsyncOpenFailed(path: path, errno: errno)
        }
        defer { close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CatalogStoreError.fsyncFailed(path: path, errno: errno)
        }
    }
}
