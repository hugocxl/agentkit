import Foundation

/// A turn the provider's usage limit stopped. The owning backend keeps it on the turn, so
/// the reset time, the retained prompt and any scheduled retry survive reconnects and restarts.
public struct AgentTurnRateLimit: Codable, Hashable, Sendable {
    /// When the provider said the limit resets, if it said.
    public var resetsAt: Date?
    /// What the provider said, one line.
    public var message: String?
    /// The prompt identity a retry is submitted under. A manual retry and a scheduled one
    /// share it, so the backend's submission ledger delivers the prompt at most once.
    public var retryPromptID: String
    /// When the backend sends the prompt again by itself: the reset time, once the user chose
    /// Resume at Reset. Nil when no retry is scheduled.
    public var retryAt: Date?
    /// Set once the retry was submitted, by either path.
    public var retried: Bool?

    public init(resetsAt: Date?, message: String?, retryPromptID: String, retryAt: Date? = nil, retried: Bool? = nil) {
        self.resetsAt = resetsAt; self.message = message; self.retryPromptID = retryPromptID
        self.retryAt = retryAt; self.retried = retried
    }

    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: retryPromptID) != nil, (message?.utf8.count ?? 0) <= 4096, message?.contains("\0") != true else {
            throw .badRequest
        }
    }

    /// The deterministic retry identity of the turn started by `turn` in `session`.
    public static func retryPromptID(session: SessionId, turn: String) -> String {
        // FNV-1a over both identities, spread into a version-5-shaped UUID: stable across
        // processes and builds, unlike Swift's seeded hashing.
        var first: UInt64 = 0xcbf2_9ce4_8422_2325, second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in Array((session.description + "\u{1F}" + turn).utf8) {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 &+ 0x9E37_79B9
        }
        var bytes = withUnsafeBytes(of: first.bigEndian, Array.init) + withUnsafeBytes(of: second.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }
}
