import Darwin
import Foundation
import CryptoKit

/// CLI runner for `goh attest [--output <file>]`.
///
/// Runs the existing `verify --all` logic, signs the canonical report bytes with the
/// Secure Enclave P-256 key, and writes a `SignedVerifyReport` artifact.
///
/// Exit codes:
///   0  — all entries OK; artifact produced.
///   2  — at least one hash MISMATCH (FAILED); artifact produced (attests drift).
///   9  — at least one file MISSING; artifact produced (attests drift).
///   6  — ledger unreadable/corrupt; NO artifact produced.
///   5  — attestation failed (SE unavailable / key error / write failure); NO artifact produced.
///   64 — usage error.
///
/// Additivity: no change to ProvenanceRecord, VerifyAllReport JSON, gohfile.lock, which,
/// or any existing exit code.
public enum GohAttestCommand {

    /// Injectable signer for testing without SE.
    public struct SignerOverride: Sendable {
        public var kid: String
        public var publicKeyX963: Data
        public var sign: @Sendable (Data) throws -> Data

        public init(kid: String, publicKeyX963: Data, sign: @Sendable @escaping (Data) throws -> Data) {
            self.kid = kid
            self.publicKeyX963 = publicKeyX963
            self.sign = sign
        }
    }

    /// Runs `goh attest`.
    ///
    /// - Parameters:
    ///   - provenanceStorePath: Path to `provenance.plist` (resolved by caller).
    ///   - outputPath: Path to write the artifact (nil → stdout).
    ///   - attestKeyHandleURL: URL of the SE key handle file.
    ///   - attestKeysJSONURL: URL of the `keys.json` history file.
    ///   - signerOverride: Inject a software signer for tests; nil uses the real SE key.
    public static func run(
        provenanceStorePath: String,
        outputPath: String?,
        attestKeyHandleURL: URL,
        attestKeysJSONURL: URL,
        signerOverride: SignerOverride? = nil
    ) -> GohCommandLineResult {

        // ── Step 1: Run verify-all ONCE to get both the verdict and the report ─
        // A single scan with a pinned timestamp. The returned exit code and the
        // report whose bytes we sign MUST describe the same ledger observation;
        // scanning twice let a file appear or disappear between the calls, so the
        // signed artifact could attest a verdict that disagreed with the exit code
        // the caller saw. One scan makes them provably consistent.
        let reportDate = Date()
        let verifyResult = GohVerifyAllCommand.run(
            provenanceStorePath: provenanceStorePath,
            json: true,
            generatedAt: reportDate)

        // Exit 6 from verify-all → ledger error, no artifact
        if verifyResult.exitCode == 6 {
            return GohCommandLineResult(
                exitCode: 6,
                standardError: "attest: ledger unreadable or corrupt\n")
        }

        // Parse the report to get payload_bytes via the seam
        guard let stdoutData = verifyResult.standardOutput.data(using: .utf8),
              stdoutData.count > 1 else {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode report for signing\n")
        }
        // Strip the trailing '\n' that --json appends
        let reportData = stdoutData.dropLast()
        guard !reportData.isEmpty,
              let report = try? CommandCoding.decoder.decode(VerifyAllReport.self, from: reportData) else {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode report for signing\n")
        }
        let payloadBytes: Data
        do {
            payloadBytes = try GohVerifyAllCommand.payloadBytes(for: report)
        } catch {
            // payloadBytes() threw — refuse to sign empty/garbage bytes; fail with exit 5.
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode report for signing: \(error)\n")
        }

        // ── Step 2: Create-or-open the signing key ────────────────────────────
        let kid: String
        let publicKeyX963: Data
        let signFn: (Data) throws -> Data

        if let override = signerOverride {
            kid = override.kid
            publicKeyX963 = override.publicKeyX963
            signFn = override.sign
        } else {
            // Real SE path
            do {
                // Create the attest directory (create:true — attest is a legitimate writer)
                let _ = try AttestKeyLocation.signingKeyHandleURL(create: true)
                let signer = try SecureEnclaveSigner.createOrOpen(handleURL: attestKeyHandleURL)
                kid = signer.kid
                publicKeyX963 = signer.publicKeyX963
                signFn = { pae in try signer.sign(pae: pae) }
                // Append to keys.json (signer-side history; never consulted on verify)
                try appendToKeysJSON(url: attestKeysJSONURL, kid: kid, pubX963: publicKeyX963)
            } catch {
                return GohCommandLineResult(
                    exitCode: 5,
                    standardError: "attest: Secure Enclave key error: \(error)\n")
            }
        }

        // ── Step 3: Build PAE and sign ────────────────────────────────────────
        let pae = SignedVerifyReport.buildPAE(
            payloadType: SignedVerifyReport.payloadType,
            payloadBytes: payloadBytes)

        let rawSig: Data
        do {
            rawSig = try signFn(pae)
        } catch {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: signing failed: \(error)\n")
        }

        // ── Step 4: Build envelope ────────────────────────────────────────────
        let envelope = SignedVerifyReport(
            attestationVersion: 1,
            payloadType: SignedVerifyReport.payloadType,
            payloadBase64: payloadBytes.base64EncodedString(),
            sig: SignedVerifyReport.SigBlock(
                ns: SignedVerifyReport.namespace,
                alg: "ES256",
                kid: kid,
                pubBase64url: publicKeyX963.base64URLEncodedString(),
                sigBase64url: rawSig.base64URLEncodedString()
            )
        )

        guard let envelopeData = try? CommandCoding.encoder.encode(envelope) else {
            return GohCommandLineResult(
                exitCode: 5,
                standardError: "attest: failed to encode artifact\n")
        }

        // ── Step 5: Write artifact (atomic) or emit to stdout ─────────────────
        if let outputPath {
            do {
                try writeArtifactAtomically(data: envelopeData, to: outputPath)
            } catch {
                return GohCommandLineResult(
                    exitCode: 5,
                    standardError: "attest: failed to write artifact: \(error)\n")
            }
        }

        // Exit code mirrors the verify verdict so `attest` drops into CI pipelines.
        let stdout = outputPath == nil
            ? String(decoding: envelopeData, as: UTF8.self) + "\n"
            : ""
        return GohCommandLineResult(
            exitCode: verifyResult.exitCode,
            standardOutput: stdout)
    }

    // MARK: - Private helpers

    /// Append-merge {kid, pub, createdAt} to keys.json (signer-side history ONLY).
    ///
    /// keys.json is NEVER read on any verification path — it exists for the signer's
    /// own reference (e.g. to look up their current kid for `--expect-key` pinning).
    private static func appendToKeysJSON(url: URL, kid: String, pubX963: Data) throws {
        struct KeysFile: Codable {
            var keysVersion: Int = 1
            var keys: [KeyEntry]
        }
        struct KeyEntry: Codable {
            var kid: String
            var pub: String       // base64url x963
            var createdAt: String // ISO-8601
        }

        var keysFile: KeysFile
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? CommandCoding.decoder.decode(KeysFile.self, from: data) {
            keysFile = existing
        } else {
            keysFile = KeysFile(keysVersion: 1, keys: [])
        }

        // Idempotent: append only if kid not already present
        if !keysFile.keys.contains(where: { $0.kid == kid }) {
            let formatter = ISO8601DateFormatter()
            keysFile.keys.append(KeyEntry(
                kid: kid,
                pub: pubX963.base64URLEncodedString(),
                createdAt: formatter.string(from: Date())
            ))
        }

        guard let data = try? CommandCoding.encoder.encode(keysFile) else { return }
        try writeAtomically(data: data, to: url, permissions: 0o600)
    }

    /// Atomic write: temp → chmod → fsync → rename → fsync(dir).
    private static func writeArtifactAtomically(data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try writeAtomically(data: data, to: url, permissions: 0o644)
    }

    private static func writeAtomically(data: Data, to url: URL, permissions: Int) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: tmp.path)
            let fd = open(tmp.path, O_RDONLY)
            if fd >= 0 {
                defer { close(fd) }
                guard Darwin.fsync(fd) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            guard rename(tmp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            let dfd = open(dir.path, O_RDONLY)
            if dfd >= 0 {
                defer { close(dfd) }
                guard Darwin.fsync(dfd) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

extension Data {
    /// Returns self if non-empty, else nil.
    var nonEmpty: Data? { isEmpty ? nil : self }
}
