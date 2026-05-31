/// Validates the `sha256:<64-lowercase-hex>` format used in gohfile.toml and gohfile.lock.
///
/// Both ManifestCodec and LockfileCodec share this validator. Do not duplicate it.
enum Sha256Format {
    static func isValid(_ s: String) -> Bool {
        guard s.hasPrefix("sha256:") else { return false }
        let hex = s.dropFirst(7)
        guard hex.count == 64 else { return false }
        return hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
