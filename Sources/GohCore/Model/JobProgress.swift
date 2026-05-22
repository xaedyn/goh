/// A job's aggregate download progress (`DESIGN.md` §1, §2.3). The per-connection
/// breakdown belongs to `goh top`'s separate subscription schema.
public struct JobProgress: Codable, Sendable, Equatable {
    /// Bytes written to disk so far.
    public var bytesCompleted: UInt64
    /// Total size, or `nil` when the server gave no length.
    public var bytesTotal: UInt64?
    /// Current aggregate throughput, bytes per second.
    public var bytesPerSecond: UInt64

    public init(bytesCompleted: UInt64, bytesTotal: UInt64?, bytesPerSecond: UInt64) {
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
    }

    private enum CodingKeys: String, CodingKey {
        case bytesCompleted, bytesTotal, bytesPerSecond
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytesCompleted = try container.decode(UInt64.self, forKey: .bytesCompleted)
        bytesTotal = try container.decodeIfPresent(UInt64.self, forKey: .bytesTotal)
        bytesPerSecond = try container.decode(UInt64.self, forKey: .bytesPerSecond)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bytesCompleted, forKey: .bytesCompleted)
        // The contract specifies `bytesTotal` as always present — `null`, not
        // omitted, when the size is unknown (`DESIGN.md` §1).
        try container.encode(bytesTotal, forKey: .bytesTotal)
        try container.encode(bytesPerSecond, forKey: .bytesPerSecond)
    }
}
