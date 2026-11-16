import Foundation

public enum InterfaceColorScheme: String, Codable, Sendable, CaseIterable {
    case auto, light, dark
}

public enum InterfaceStyle: String, Codable, Sendable, CaseIterable {
    case classic, glass
}

public enum InterfaceAnimation: String, Codable, Sendable, CaseIterable {
    case snappy, natural, off
}

/// Appearance options shared by all conversation surfaces.
public struct Appearance: Equatable, Sendable {
    public var colorScheme: InterfaceColorScheme = .auto
    public var interfaceStyle: InterfaceStyle = .classic
    public var glassPanes = false
    public var animationStyle: InterfaceAnimation = .natural
    public init() {}
}
