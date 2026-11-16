public enum AgentLimits {
    /// The largest frame payload, unless a connection sets a smaller one.
    public static let maxFrame = 16 * 1024 * 1024
    public static let maxCols: UInt16 = 4096
    public static let maxRows: UInt16 = 1024
    public static let maxLinkSpans = 1024
    public static let maxLinkURI = 2048
    /// The most an OSC 52 clipboard write carries.
    public static let maxClipboardText = 1024 * 1024
    /// The most one input write carries.
    public static let maxInput = 1024 * 1024
    public static let maxPathBytes = 4096
    public static let maxGraphicsBytes = 8 * 1024 * 1024
    public static let maxGraphicsPlacements = 1024
    public static let catalogPageSize = 128
    public static let maxProjects = 4096
    /// The most tabs a server keeps, across its projects.
    public static let maxTabs = 1024
    public static let maxPanesPerTab = 64
    public static let maxHistoryPage = 500
    public static let maxAttachHistory = 200
    public static let maxSearchQuery = 256
    public static let maxSearchScannedRows: UInt64 = 2000
    public static let maxSessionReferences = 16_384
    public static let activityHistoryLimit = 200
    /// The most a terminal notification's title or text keeps, in bytes.
    public static let maxNotificationText = 1024
    public static let maxFileBytes = 5 * 1024 * 1024
    public static let maxFileEntries = 16_384
    public static let maxFilePathBytes = 2 * 1024 * 1024
    public static let maxFileChanges = 256
    public static let maxFileSearchResults = 100_000
    /// Content search matches kept per file.
    public static let maxMatchesPerFile = 200
    public static let maxExecOutput = 4 * 1024 * 1024
    public static let maxExecTimeoutMs: UInt32 = 300_000
    public static let maxUploadChunk = 1024 * 1024
    public static let maxUploadBytes: UInt64 = 100 * 1024 * 1024
    public static let maxUploadName = 1024
    public static let maxEnvironmentVariables = 128
    public static let maxEnvironmentBytes = 64 * 1024
    public static let maxDevices = 64
    /// The most tunnels one connection keeps open.
    public static let maxTunnelsPerConnection = 256
    /// The most one `stream` frame carries.
    public static let maxStreamChunk = 64 * 1024
    /// The bytes each direction of a tunnel may send before the reader grants credit.
    public static let tunnelWindow: UInt32 = 512 * 1024
    public static let maxTunnelHost = 255
    /// The most input one simulator message carries.
    public static let maxSimulatorInput = 1024
    /// The most simulators a listing returns.
    public static let maxSimulatorList = 1024
    public static let maxDeviceName = 64
    public static let maxPairingHosts = 8
    public static let defaultRemotePort: UInt16 = 7419
    public static let maxHistoryBudgetBytes: UInt64 = 64 * 1024 * 1024 * 1024
}
