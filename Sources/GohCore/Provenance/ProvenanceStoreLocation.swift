import Foundation

/// Resolves the canonical path of `provenance.plist` so the daemon writer and
/// the CLI readers (`goh which`, `goh verify --all`) always point at the same file.
///
/// This is the single anti-divergence point: both the daemon and the CLI call
/// `ProvenanceStoreLocation.defaultURL(create:)` — never a hard-coded path.
public enum ProvenanceStoreLocation {

    /// `~/Library/Application Support/dev.goh.daemon/provenance.plist`.
    ///
    /// - Parameter create: When `true` (daemon path), the `dev.goh.daemon`
    ///   subdirectory is created with `withIntermediateDirectories: true` — exactly
    ///   preserving the daemon's first-run behaviour. When `false` (CLI read paths),
    ///   no directory is created; a missing dir/file is "no store" (silent fall-through).
    public static func defaultURL(create: Bool) throws -> URL {
        try supportDirectoryURL(create: create).appending(path: "provenance.plist")
    }

    /// The support directory `~/Library/Application Support/<machServiceName>`.
    ///
    /// Factored out of `gohd/main.swift`'s `supportDirectoryURL()` so daemon and
    /// CLI share one definition. The daemon should call this with `create: true`
    /// to preserve its existing directory-creation behaviour (load-bearing for
    /// `CatalogStore`/`HostProfileStore`/`CheckpointStore` on a clean install — those
    /// stores do not self-create their parent).
    public static func supportDirectoryURL(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create)
        let directory = support.appending(
            path: GohXPCService.machServiceName, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
