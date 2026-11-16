import AgentCore
import Foundation

/// Read-only pull-request metadata for an in-message link, without exposing
/// generic API requests, credentials, PR mutations or other project operations.
@MainActor
enum AgentConversationPullRequestPreview {
    struct Target: Equatable {
        var host: String
        var repository: String
        var number: UInt64
    }

    /// `https://<host>/<owner>/<repo>/pull/<number>`, with optional trailing segments.
    static func target(from url: URL) -> Target? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = UInt64(parts[3]) else { return nil }
        let target = Target(host: host, repository: parts[0] + "/" + parts[1], number: number)
        guard (try? GitPullRequestPreview.validateTarget(host: target.host, repository: target.repository, number: number)) != nil else { return nil }
        return target
    }

}
