import Foundation

/// Lexical + realpath path confinement for `goh sync` destinations (spec §4.1
/// rules 1–2).
///
/// `goh sync` resolves each `[[asset]]`'s `path` relative to the manifest's
/// `base` directory. A malicious or careless manifest must never be able to
/// write outside `base`. This enum is the CLI-side gate that runs *before* any
/// download is started:
///
/// 1. The entry path must be relative — never absolute (`/…`) or drive-form
///    (`X:…`). A literal `~` or `$` in the entry path is taken literally and is
///    never expanded (spec §7.4); only `base` may have had a leading `~`
///    expanded by the caller before `resolve` is called.
/// 2. `base/entryPath` is lexically normalized before any filesystem call. If
///    the normalized result is not `base` itself and does not sit under
///    `base + "/"` (i.e. a `..` climbed to or above `base`), it is refused.
/// 3. The realpath of the destination's *parent* must equal or sit under
///    `base`'s realpath. This catches a symlinked intermediate directory that
///    lives under `base` but resolves outside it. The final file itself may not
///    exist yet, so only the parent is realpath-checked.
public enum SyncPathConfinement {

    /// A refusal to resolve an entry path within its base.
    public struct ConfinementError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Resolves `entryPath` against `base`, returning the absolute destination
    /// path, or throws ``ConfinementError`` if the entry would escape `base`.
    ///
    /// - Parameters:
    ///   - entryPath: The manifest `[[asset]]` path. Must be relative; tildes
    ///     and dollar signs are literal.
    ///   - base: The confinement root, already absolute and (by the caller)
    ///     tilde-expanded. Need not yet be realpath-canonical; this function
    ///     canonicalizes it internally for the comparisons.
    /// - Returns: The absolute, lexically-normalized destination path.
    public static func resolve(entryPath: String, base: String) throws -> String {
        // ── Rule 1: reject absolute or drive-form entry paths ────────────────
        if entryPath.hasPrefix("/") {
            throw ConfinementError("entry path must be relative, not absolute: \(entryPath)")
        }
        if isDriveForm(entryPath) {
            throw ConfinementError("entry path must be relative, not drive-form: \(entryPath)")
        }
        if entryPath.isEmpty {
            throw ConfinementError("entry path is empty")
        }

        // The realpath-canonical base is the comparison root for both the
        // lexical check and the parent realpath check. Canonicalizing base
        // (not the join) keeps a `~cache`-style literal segment in the entry
        // path intact instead of being treated as a home directory.
        let canonicalBase = URL(fileURLWithPath: base).resolvingSymlinksInPath().path

        // ── Rule 2: lexical normalization, no filesystem access ──────────────
        // Join under the canonical base and standardize (collapses `.` and `..`
        // purely lexically). `~` and `$` are ordinary characters here.
        let joined = URL(fileURLWithPath: canonicalBase)
            .appendingPathComponent(entryPath)
        let normalized = joined.standardizedFileURL.path

        if normalized != canonicalBase && !normalized.hasPrefix(canonicalBase + "/") {
            throw ConfinementError("entry path escapes base: \(entryPath)")
        }
        if normalized == canonicalBase {
            throw ConfinementError("entry path resolves to the base directory itself: \(entryPath)")
        }

        // ── Rule 3: realpath the parent and confirm it stays under base ──────
        // The final file may not exist yet, so only the parent is resolved.
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        let realParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path

        if realParent != canonicalBase && !realParent.hasPrefix(canonicalBase + "/") {
            throw ConfinementError(
                "entry path's parent directory resolves outside base (symlink escape): \(entryPath)")
        }

        return normalized
    }

    /// Whether `path` begins with a Windows-style drive specifier such as
    /// `C:` or `Z:foo`. Defensive: such a form is never a valid relative POSIX
    /// path and could be mishandled downstream.
    private static func isDriveForm(_ path: String) -> Bool {
        guard let colonIndex = path.firstIndex(of: ":") else { return false }
        let drive = path[path.startIndex..<colonIndex]
        return drive.count == 1 && drive.allSatisfy { $0.isLetter }
    }
}
