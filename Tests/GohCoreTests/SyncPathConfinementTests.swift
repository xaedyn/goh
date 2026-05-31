import Foundation
import Testing
@testable import GohCore

/// Creates a fresh temporary directory and returns its realpath-canonicalized
/// absolute path, so tests compare against the resolver's own canonical base.
private func makeTempBase() throws -> String {
    let raw = FileManager.default.temporaryDirectory
        .appendingPathComponent("goh-confine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    return URL(fileURLWithPath: raw.path).resolvingSymlinksInPath().path
}

@Test("absolute entry path is rejected")
func confinementRejectsAbsolute() throws {
    let base = try makeTempBase()
    #expect(throws: SyncPathConfinement.ConfinementError.self) {
        _ = try SyncPathConfinement.resolve(entryPath: "/etc/passwd", base: base)
    }
}

@Test("drive-form entry path is rejected")
func confinementRejectsDriveForm() throws {
    let base = try makeTempBase()
    #expect(throws: SyncPathConfinement.ConfinementError.self) {
        _ = try SyncPathConfinement.resolve(entryPath: "C:evil", base: base)
    }
}

@Test("a parent-climbing entry path that escapes the base is rejected")
func confinementRejectsEscape() throws {
    let base = try makeTempBase()
    #expect(throws: SyncPathConfinement.ConfinementError.self) {
        _ = try SyncPathConfinement.resolve(entryPath: "../escape.bin", base: base)
    }
}

@Test("a valid subdirectory path resolves under the base")
func confinementResolvesSubdir() throws {
    let base = try makeTempBase()
    let resolved = try SyncPathConfinement.resolve(entryPath: "subdir/file.bin", base: base)
    #expect(resolved == base + "/subdir/file.bin")
}

@Test("a plain valid path returns an absolute string under the base")
func confinementResolvesPlain() throws {
    let base = try makeTempBase()
    let resolved = try SyncPathConfinement.resolve(entryPath: "file.bin", base: base)
    #expect(resolved == base + "/file.bin")
    #expect(resolved.hasPrefix("/"))
}

@Test("a leading tilde in the entry path is literal, not home-expanded")
func confinementTildeIsLiteral() throws {
    let base = try makeTempBase()
    let resolved = try SyncPathConfinement.resolve(entryPath: "~cache/file.bin", base: base)
    // Stays under base; the tilde is a literal directory-name character.
    #expect(resolved == base + "/~cache/file.bin")
    #expect(!resolved.hasPrefix(NSHomeDirectory()))
}

@Test("a symlinked intermediate under base pointing outside is rejected by realpath")
func confinementRejectsSymlinkedParentEscape() throws {
    let base = try makeTempBase()
    // Create an out-of-base target directory and a symlink "link" under base
    // that points to it. Lexical normalization sees base/link/file.bin (under
    // base), but realpath of the parent escapes.
    let outside = try makeTempBase()
    let link = base + "/link"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
    #expect(throws: SyncPathConfinement.ConfinementError.self) {
        _ = try SyncPathConfinement.resolve(entryPath: "link/file.bin", base: base)
    }
}
