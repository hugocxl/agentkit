import Foundation
public enum NotificationPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, top, topRight, bottomLeft, bottom, bottomRight

    public var title: String {
        switch self {
        case .topLeft: return "top left"
        case .top: return "top center"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottom: return "bottom center"
        case .bottomRight: return "bottom right"
        }
    }

    public var isTop: Bool { [.topLeft, .top, .topRight].contains(self) }

    /// -1 for the left edge, 0 for the center, 1 for the right edge.
    public var column: Int {
        switch self {
        case .topLeft, .bottomLeft: return -1
        case .top, .bottom: return 0
        case .topRight, .bottomRight: return 1
        }
    }

    /// Positions from newer builds read as bottom right.
    public init(from decoder: Decoder) throws {
        self = NotificationPosition(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bottomRight
    }
}