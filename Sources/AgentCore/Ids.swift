import Foundation

public protocol UUIDIdentifier: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    var uuid: UUID { get }
    init(uuid: UUID)
}

extension UUIDIdentifier {
    /// A new random identifier.
    public init() { self.init(uuid: UUID()) }

    /// Parses a UUID string in either case; `nil` when it isn't one.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(uuid: uuid)
    }

    public var description: String { uuid.uuidString.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a UUID: \(text)")
        }
        self.init(uuid: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct ProjectId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct SessionId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

public struct OperationId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

extension UUIDIdentifier {
    /// Parses a UUID with or without hyphens, in any case, as hand-edited
    /// settings and `uuidgen` output spell them.
    public init?(_ text: String) {
        guard let uuid = parseUUID(text) else { return nil }
        self.init(uuid: uuid)
    }

    /// For `CodingKeyRepresentable`: ids are JSON object keys.
    public var codingKey: CodingKey { IdentifierCodingKey(stringValue: description) }

    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
}


extension ProjectId: CodingKeyRepresentable {}
extension SessionId: CodingKeyRepresentable {}
extension OperationId: CodingKeyRepresentable {}

private struct IdentifierCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

func parseUUID(_ text: String) -> UUID? {
    if let uuid = UUID(uuidString: text) { return uuid }
    let hex = text.replacingOccurrences(of: "-", with: "")
    guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
    let characters = Array(hex)
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }
    return UUID(uuidString: groups.joined(separator: "-"))
}
