import AppKit
import AgentCore

/// File access and navigation supplied by the embedding application.
@MainActor
protocol AgentConversationProjectActions: AnyObject {
    var isLocal: Bool { get }
    func refreshProjectMetadata()
    func searchProjectEntries(_ query: String, limit: Int) async throws -> AgentConversationFileActions.Entries
    func filesystemMetadata(_ paths: [String]) async throws -> [AgentConversationFileActions.Metadata?]
    func workspaceMedia(_ path: String, cwd: String?) async throws -> AgentConversationFileActions.Media
    func writeProjectFile(_ relativePath: String, contents: String, cwd: String?) async throws -> String
    func pullRequestPreview(_ url: URL) async throws -> GitPullRequestPreview
    func openEditor(_ target: String, reveal: Bool) throws
    func openFileInBrowser(_ path: String) throws
    func openBrowser(_ url: URL) throws
    func previewFile(_ path: String) async throws
    func openConversation(_ target: SessionId, project: ProjectId?, citation: AgentAssistantCitation?) async throws
}
