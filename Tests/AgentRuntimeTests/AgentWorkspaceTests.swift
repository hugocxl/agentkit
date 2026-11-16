import Foundation
import XCTest
import AgentCore
@testable import AgentRuntime

final class AgentWorkspaceTests: XCTestCase {
    private func folders() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-\(UUID())")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (work, root.appendingPathComponent("state"))
    }

    func testPublicConnectionRestoresConversationAndRejectsAnotherWorkspace() async throws {
        let (work, storage) = try folders(), project = ProjectId(), session = SessionId()
        let first = try AgentWorkspace(workingDirectory: work, storageDirectory: storage, project: project)
        let connection = first.connect(provider: .claude, session: session)
        let snapshot = try await connection.request(.create(session: session, project: project, provider: .claude))
        XCTAssertEqual(snapshot.session, session)
        do {
            _ = try await connection.request(.create(session: SessionId(), project: ProjectId(), provider: .claude))
            XCTFail("Another workspace must not acquire this directory")
        } catch { XCTAssertEqual(agentErrorCode(error), .unknownProject) }
        first.shutdown()
        let reopened = try AgentWorkspace(workingDirectory: work, storageDirectory: storage, project: project)
        defer { reopened.shutdown() }
        let restored = try await reopened.connect(provider: .claude, session: session).request(.read(session: session))
        XCTAssertEqual(restored.session, session)
        XCTAssertEqual(restored.project, project)
    }

    func testObserversReceiveTheSameRevisionAndFinishAtShutdown() async throws {
        let (work, storage) = try folders(), project = ProjectId()
        let workspace = try AgentWorkspace(workingDirectory: work, storageDirectory: storage, project: project)
        let connection = workspace.connect(provider: .claude)
        let first = connection.observe(), second = connection.observe()
        let received = expectation(description: "both observers"); received.expectedFulfillmentCount = 2
        let ended = expectation(description: "both streams finish"); ended.expectedFulfillmentCount = 2
        let tasks = [first, second].map { stream in
            Task {
                var observed = false
                for await change in stream {
                    XCTAssertEqual(change.session, connection.session)
                    if !observed { observed = true; received.fulfill() }
                }
                ended.fulfill()
            }
        }
        _ = try await connection.request(.create(session: connection.session, project: project, provider: .claude))
        await fulfillment(of: [received], timeout: 3)
        workspace.shutdown()
        await fulfillment(of: [ended], timeout: 3)
        for task in tasks { await task.value }
    }

    func testPublicExecutableOverrideStreamsAndPersistsRealSubprocessOutput() async throws {
        let (work, storage) = try folders(), project = ProjectId()
        let executable = work.appendingPathComponent("fake-provider")
        let source = #"""
        #!/bin/sh
        while IFS= read -r line; do
            case "$line" in
                *'"type":"control_request"'*)
                    id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
                    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
                    ;;
                *'"type":"user"'*)
                    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Hello from the test provider"}'
                    ;;
            esac
        done
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let workspace = try AgentWorkspace(workingDirectory: work, storageDirectory: storage, project: project,
                                           executables: [.claude: executable])
        defer { workspace.shutdown() }
        let connection = workspace.connect(provider: .claude)
        _ = try await connection.request(.create(session: connection.session, project: project, provider: .claude))
        let completed = expectation(description: "subprocess reply")
        let changes = connection.observe()
        let observer = Task {
            for await _ in changes {
                let snapshot = try await connection.request(.read(session: connection.session))
                if snapshot.items.contains(where: { $0.kind == .assistant && $0.text.contains("Hello from the test provider") }) {
                    completed.fulfill(); return
                }
            }
        }
        defer { observer.cancel() }
        _ = try await connection.request(.send(session: connection.session, text: "hello", model: nil))
        await fulfillment(of: [completed], timeout: 5)
    }

    func testApplicationWorkspaceRejectsAccessEscalationAndFileRollback() async throws {
        let (work, storage) = try folders()
        let workspace = try AgentWorkspace(workingDirectory: work, storageDirectory: storage, project: ProjectId(),
                                           tools: .init([]) { _ in .init(text: "") })
        defer { workspace.shutdown() }
        let connection = workspace.connect(provider: .codex)
        _ = try await connection.request(.create(session: connection.session, project: workspace.project, provider: .codex))
        for request in [AgentChatRequest.setAccess(session: connection.session, mode: .fullAccess),
                        .setPlan(session: connection.session, enabled: true)] {
            do { _ = try await connection.request(request); XCTFail("Application access cannot be widened") }
            catch { XCTAssertTrue(error is ModelError) }
        }
        do {
            _ = try await connection.conversation?(.revert(session: connection.session, checkpoint: "anything", paths: nil, force: true))
            XCTFail("Host undo must own app edits")
        } catch { XCTAssertTrue(error is ModelError) }
        XCTAssertNil(connection.checkpoint)
        XCTAssertNil(connection.importHistory)
        XCTAssertFalse(connection.capabilities.contains(.planMode))
    }

    func testLocalFilesRejectEscapingLinksAndChangedMediaRevisions() async throws {
        let (work, _) = try folders(), project = ProjectId()
        let outside = work.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        let files = try AgentLocalFiles(directory: work, project: project)
        do {
            _ = try await files.handle(.init(project: project, action: .readBytes(ServerPath("escape.txt"))))
            XCTFail("A link outside the working folder must not be read")
        } catch { XCTAssertEqual(agentErrorCode(error), .badPath) }
        let media = work.appendingPathComponent("video.bin")
        try Data(repeating: 1, count: 512).write(to: media)
        guard case .byteRange(let first) = try await files.handle(.init(project: project,
            action: .readRange(path: ServerPath("video.bin"), offset: 0, length: 64, expectedRevision: nil))) else { return XCTFail("Missing range") }
        try Data(repeating: 2, count: 1024).write(to: media, options: .atomic)
        do {
            _ = try await files.handle(.init(project: project, action: .readRange(path: ServerPath("video.bin"), offset: 64, length: 64, expectedRevision: first.revision)))
            XCTFail("Changed media must not splice two file revisions together")
        } catch { XCTAssertEqual(agentErrorCode(error), .badRequest) }
    }
}
