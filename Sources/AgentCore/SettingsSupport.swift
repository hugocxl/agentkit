import Foundation

/// A settings problem, naming the setting it is about.
public struct SettingsError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The setting, such as `keymap.split_right` or a file path.
    public let key: String
    public let message: String

    public init(_ key: String, _ message: String) {
        self.key = key
        self.message = message
    }

    public var description: String { "\(key): \(message)" }
    public var errorDescription: String? { description }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when the key is missing or null.
    /// Present values of the wrong type still fail.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
