import Darwin
import Foundation
import XPC

/// CLI runner for `goh forget` — removes provenance-ledger entries.
///
/// Grammar (parsed by GohCommandLine.parse, routed here):
///   goh forget <path>                  explicit single-path forget
///   goh forget --missing               dry-run: list absent entries, delete nothing
///   goh forget --missing --confirm     delete absent entries
///
/// DESIGN reference: Preview-and-Confirm approach (THE BET: users prefer an
/// explicit two-step over a one-step TTY prompt). Dry-run is the default for
/// bulk `--missing`; `--confirm` is the second step. Explicit `<path>` is
/// immediate (git-rm model — naming the target IS the confirmation).
///
/// featureLevel gate: before any mutating send, a FRESH `.ls` reads
/// `LsReply.featureLevel`. `nil` or `< 2` → error + exit 1, no send.
/// XPC unreachable → error + exit 1, no send.
public enum GohForgetCommand {

    // MARK: - Public entry points

    /// Explicit single-path forget: `goh forget <path>`.
    ///
    /// - Parameters:
    ///   - path: Raw user-supplied path (canonicalized internally).
    ///   - provenanceStorePath: Resolved path from `provenanceStorePathResolver`.
    ///   - send: XPC sender closure (injectable for tests).
    /// - Returns: A CLI result (exitCode, stdout, stderr).
    public static func run(
        path: String,
        provenanceStorePath: String,
        send: @escaping GohCommandLine.Sender
    ) -> GohCommandLineResult {
        // Step 1: Read-only lookup — no daemon contact.
        // AC3: if not tracked, exit 1. Corrupt ledger → exit 6 (not a silent "not tracked").
        // `canonical` is declared before the switch so Steps 2 and 3 can use it in scope.
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        switch ProvenanceLedgerReader.read(at: provenanceStorePath) {
        case .unreadable(.io):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger unreadable\n")
        case .unreadable(.corrupt):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger corrupt\n")
        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "goh forget: provenance ledger version \(found) is unknown\n")
        case .absent:
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: \(path) is not tracked (no provenance entry)\n")
        case .entries(let entries):
            // Path present but no matching entry → not tracked.
            guard entries.contains(where: { $0.destinationPath == canonical }) else {
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: \(path) is not tracked (no provenance entry)\n")
            }
            // Entry exists — fall through to featureLevel gate + send.
        }

        // Step 2: featureLevel gate — fresh .ls required before any mutating send.
        switch featureLevelGateResult(send: send) {
        case .proceed:
            break
        case .failure(let result):
            return result
        }

        // Step 3: Send one forgetProvenance command.
        let client = GohCommandClient(send: send)
        do {
            let reply: ForgetProvenanceReply = try client.send(
                .forgetProvenance(request: ForgetProvenanceRequest(paths: [canonical])),
                expecting: ForgetProvenanceReply.self)
            if reply.forgotCount == 1 {
                return GohCommandLineResult(exitCode: 0, standardOutput: "Forgot \(canonical).\n")
            } else {
                // forgotCount == 0: rare race — path was removed between lookup and send.
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: \(canonical) was no longer tracked\n")
            }
        } catch let error as GohCommandClientError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: commandClientErrorMessage(error))
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: transport error: \(error)\n")
        }
    }

    /// `--missing` path: dry-run preview or `--confirm` delete.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Resolved path from `provenanceStorePathResolver`.
    ///   - confirm: `true` when `--confirm` was passed; `false` for dry-run.
    ///   - send: XPC sender closure (injectable for tests).
    ///   - probe: Injectable lstat probe (default `LiveFileStatProbe()`).
    ///   - mountedVolumeURLs: Injectable volume URL resolver (default Foundation API).
    public static func runMissing(
        provenanceStorePath: String,
        confirm: Bool,
        send: @escaping GohCommandLine.Sender,
        probe: any FileStatProbing = LiveFileStatProbe(),
        mountedVolumeURLs: () -> [URL]? = {
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])
        }
    ) -> GohCommandLineResult {
        // Step 1: Read ledger read-only.
        let outcome = ProvenanceLedgerReader.read(at: provenanceStorePath)
        switch outcome {
        case .absent, .entries([]):
            return GohCommandLineResult(exitCode: 0, standardOutput: "No tracked entries.\n")
        case .unreadable(.io):
            return GohCommandLineResult(exitCode: 6, standardError: "provenance ledger unreadable\n")
        case .unreadable(.corrupt):
            return GohCommandLineResult(exitCode: 6, standardError: "provenance ledger corrupt\n")
        case .unreadable(.versionUnknown(let found)):
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "provenance ledger version \(found) is unknown\n")
        case .entries(let entries):
            return processMissing(
                entries: entries,
                confirm: confirm,
                send: send,
                probe: probe,
                mountedVolumeURLs: mountedVolumeURLs)
        }
    }

    // MARK: - Private

    private enum GateResult {
        case proceed
        case failure(GohCommandLineResult)
    }

    /// Sends a fresh `.ls`, reads featureLevel, and returns whether it is safe to send
    /// `forgetProvenance`. This is the NEW gate specific to forget — NOT DaemonAutoHeal.
    /// Its return value is exit-code-affecting (not best-effort), and it distinguishes
    /// "XPC unreachable" from "featureLevel too low" — two things DaemonAutoHeal.runIfNeeded
    /// conflates into a discardable String? return.
    ///
    /// Spec advisory (1): GohCommandClient.send throws GohCommandClientError.daemon(GohError)
    /// when the daemon sends a .error envelope; throws GohCommandClientError.malformedReply
    /// for decode failures; and throws a transport error when XPC is unreachable. All three
    /// paths reach the `catch` below and produce "cannot reach" + exit 1 (correct, since if
    /// we can't classify featureLevel we must not proceed).
    private static func featureLevelGateResult(send: @escaping GohCommandLine.Sender) -> GateResult {
        let client = GohCommandClient(send: send)
        let lsReply: LsReply
        do {
            lsReply = try client.send(.ls, expecting: LsReply.self)
        } catch {
            return .failure(GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: cannot reach the goh daemon — is it running? try: goh daemon restart\n"))
        }
        guard let featureLevel = lsReply.featureLevel, featureLevel >= 2 else {
            return .failure(GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: this goh daemon is too old to support forget — restart it: goh daemon restart\n"))
        }
        return .proceed
    }

    private static func processMissing(
        entries: [ProvenanceEntry],
        confirm: Bool,
        send: @escaping GohCommandLine.Sender,
        probe: any FileStatProbing,
        mountedVolumeURLs: () -> [URL]?
    ) -> GohCommandLineResult {
        // Step 2: lstat each entry; candidates are exactly .notFound (ENOENT).
        let candidates = entries.filter { probe.probe(path: $0.destinationPath) == .notFound }

        if candidates.isEmpty {
            return GohCommandLineResult(exitCode: 0, standardOutput: "No missing entries.\n")
        }

        if !confirm {
            // Dry-run: print candidate list with mount annotation. Delete nothing.
            let volumes: [URL]? = mountedVolumeURLs()
            var lines: [String] = []
            for entry in candidates {
                let annotation = mountAnnotation(for: entry.destinationPath, mountedVolumes: volumes)
                lines.append("MISSING   \(entry.destinationPath)\(annotation)\n")
            }
            let n = candidates.count
            lines.append("\(n) entr\(n == 1 ? "y" : "ies") missing; re-run with --confirm to forget them\n")
            return GohCommandLineResult(exitCode: 0, standardOutput: lines.joined())
        }

        // --confirm path: featureLevel gate first.
        switch featureLevelGateResult(send: send) {
        case .proceed:
            break
        case .failure(let result):
            return result
        }

        // Send one forgetProvenance with the stored destinationPath strings VERBATIM.
        // AC2: paths are NOT re-canonicalized — they were already stored canonical.
        // This is the tested invariant: forgotCount == K by construction on --missing.
        let verbatimPaths = candidates.map { $0.destinationPath }
        let client = GohCommandClient(send: send)
        do {
            let reply: ForgetProvenanceReply = try client.send(
                .forgetProvenance(request: ForgetProvenanceRequest(paths: verbatimPaths)),
                expecting: ForgetProvenanceReply.self)
            let k = verbatimPaths.count
            if reply.forgotCount == k {
                let n = reply.forgotCount
                return GohCommandLineResult(
                    exitCode: 0,
                    standardOutput: "Forgot \(n) entr\(n == 1 ? "y" : "ies").\n")
            } else {
                let got = reply.forgotCount
                let still = k - got
                return GohCommandLineResult(
                    exitCode: 1,
                    standardError: "goh forget: forgot \(got) of \(k) entr\(k == 1 ? "y" : "ies"); \(still) still tracked\n")
            }
        } catch let error as GohCommandClientError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: commandClientErrorMessage(error))
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "goh forget: transport error: \(error)\n")
        }
    }

    /// Returns the mount annotation string for a path (empty string or "   (VOLUME NOT MOUNTED)").
    ///
    /// Mount detection uses component-boundary prefix matching (not raw string hasPrefix),
    /// so /Volumes/Arc does not falsely match /Volumes/Archive. Picks the longest match.
    /// If `mountedVolumes` is nil (FileManager returned nil), degrades gracefully: returns "".
    private static func mountAnnotation(for path: String, mountedVolumes: [URL]?) -> String {
        guard let volumes = mountedVolumes else {
            // nil return from mountedVolumeURLs → degrade gracefully, no annotation.
            return ""
        }
        let pathComponents = (path as NSString).pathComponents
        var bestMatchLength = 0
        for volumeURL in volumes {
            let vComponents = volumeURL.standardizedFileURL.pathComponents
            guard vComponents.count <= pathComponents.count else { continue }
            // Component-boundary match: every volume component must equal the corresponding path component.
            let matches = zip(vComponents, pathComponents).allSatisfy { $0 == $1 }
            if matches, vComponents.count > bestMatchLength {
                bestMatchLength = vComponents.count
            }
        }
        if bestMatchLength > 0 {
            // Path is on a currently-mounted volume — bare MISSING line.
            return ""
        } else {
            // No mounted volume is a component-boundary prefix — likely detached drive.
            return "   (VOLUME NOT MOUNTED)"
        }
    }

    private static func commandClientErrorMessage(_ error: GohCommandClientError) -> String {
        switch error {
        case .daemon(let gohError):
            let detail = gohError.message ?? gohError.code.rawValue
            return "goh forget: daemon error: \(detail)\n"
        case .malformedReply(let msg):
            return "goh forget: daemon returned an invalid reply: \(msg)\n"
        }
    }
}
