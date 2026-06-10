/// Monotonic integer bumped per release that adds daemon behavior a client
/// depends on. Distinct from the frozen wire `protocolVersion`; featureLevel 1
/// = "daemon writes stat baselines on recordVerified" (DESIGN.md §3).
///
/// Bumping this is a deliberate release step — document the bump in DESIGN.md
/// like protocolVersion. Never auto-bumped.
public enum GohFeatureLevel {
    /// The feature level compiled into this build.
    public static let current: Int = 1
}
