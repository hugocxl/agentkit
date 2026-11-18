/// Optional backend features. A text-and-tool transport can use an empty set;
/// the native UI then omits controls that the backend cannot honor.
public struct AgentCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let modelSelection = Self(rawValue: 1 << 0)
    public static let planMode = Self(rawValue: 1 << 1)
    public static let attachments = Self(rawValue: 1 << 2)
    public static let promptQueue = Self(rawValue: 1 << 3)
    public static let providerCommands = Self(rawValue: 1 << 4)
    /// The backend can hand a queued prompt to the running turn (`deliverQueued` while working),
    /// so the composer offers Send Now beside the default of queueing.
    public static let steering = Self(rawValue: 1 << 5)
    public static let all: Self = [.modelSelection, .planMode, .attachments, .promptQueue, .providerCommands, .steering]
}
