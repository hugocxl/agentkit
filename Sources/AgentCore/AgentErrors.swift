import Foundation
public struct ServiceError: Error, Sendable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String

    public init(_ code: ErrorCode = .badRequest, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}
public extension ServiceError {
    static func unknownSession(_ id: SessionId) -> ServiceError { ServiceError(.unknownSession, "Unknown conversation: \(id)") }
}
/// An error whose code may be interpreted across a transport boundary.
public protocol AgentCodedError: Error { var agentErrorCode: ErrorCode? { get } }
extension ServiceError: AgentCodedError { public var agentErrorCode: ErrorCode? { code } }
extension ErrorReply: AgentCodedError { public var agentErrorCode: ErrorCode? { code } }
extension ErrorCode: AgentCodedError { public var agentErrorCode: ErrorCode? { self } }
public func agentErrorCode(_ error: Error) -> ErrorCode? { (error as? any AgentCodedError)?.agentErrorCode }
/// A user-facing conversation error.
public struct ModelError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
