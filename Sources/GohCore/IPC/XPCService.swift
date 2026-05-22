/// Whether XPC peer code-signature validation is enforced.
public enum PeerValidationMode: Sendable, Equatable {
    /// Production: the peer's code signature is validated against the genuine
    /// `goh` / `gohd` identity. This is the only mode in a release build.
    case enforced
    /// Development only: peer validation is skipped. Reachable solely in a
    /// `DEBUG` build with the opt-in environment variable set — the relaxation
    /// is compiled out of release builds entirely.
    case relaxedForDevelopment
}

/// The `goh` ⇄ `gohd` XPC service identity and peer-validation policy
/// (see `DESIGN.md` §3).
public enum GohXPCService {
    /// The Mach service name `gohd` advertises and `goh` connects to. Must match
    /// the `MachServices` key in `Resources/dev.goh.daemon.plist` — a test
    /// enforces that.
    public static let machServiceName = "dev.goh.daemon"

    /// The environment variable that opts a `DEBUG` build into the development
    /// peer-validation relaxation. Has no effect in a release build.
    public static let developmentRelaxationEnvironmentKey = "GOH_XPC_ALLOW_UNVALIDATED_PEERS"

    /// Resolves the peer-validation mode for the given process environment.
    ///
    /// The result is always `.enforced` except in a `DEBUG` build where
    /// `developmentRelaxationEnvironmentKey` is present. The relaxation branch is
    /// compiled out of release builds entirely, so a shipped binary cannot skip
    /// validation regardless of its environment.
    public static func peerValidationMode(
        environment: [String: String]
    ) -> PeerValidationMode {
        #if DEBUG
        // Tripwire: the relaxation must never coexist with a release build. If a
        // future release configuration ever defines `RELEASE` alongside `DEBUG`,
        // fail the build rather than ship a binary that can skip validation.
        #if RELEASE
        #error("DEBUG and RELEASE are both defined — the development peer-validation relaxation must never compile into a release build.")
        #endif
        if environment[developmentRelaxationEnvironmentKey] != nil {
            return .relaxedForDevelopment
        }
        #endif
        return .enforced
    }
}
