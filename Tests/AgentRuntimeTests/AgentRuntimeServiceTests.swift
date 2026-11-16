import Foundation
import XCTest
import AgentCore
import AgentRuntime

final class AgentRuntimeServiceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLegacyStoreClearsInPlaceAndRetainsArchiveAcrossRestart() async throws {
        let root = try root(), storage = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let project = ProjectId(), session = SessionId(), archive = SessionId()
        let original = AgentChatSnapshot(session: session, project: project, provider: .claude, revision: 7,
                                        items: [.init(id: "original", kind: .user, text: "Retained before migration")])
        // The old host persisted only these required keys; new optional fields are absent.
        let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        let legacy = try JSONSerialization.data(withJSONObject: ["snapshot": snapshot, "directory": root.path])
        try legacy.write(to: storage.appendingPathComponent("\(session).json"))
        let runtime = try AgentRuntimeService(storageDirectory: storage, home: root, projectDirectory: { _ in root })
        let restored = try await runtime.handle(.read(session: session))
        XCTAssertEqual(restored.items, original.items)
        let cleared = try await runtime.handle(.clear(session: session, archive: archive, expectedRevision: restored.revision))
        XCTAssertEqual(cleared.session, session)
        XCTAssertEqual(cleared.resetID, archive)
        XCTAssertTrue(cleared.items.isEmpty)
        runtime.shutdown()
        let reopened = try AgentRuntimeService(storageDirectory: storage, home: root, projectDirectory: { _ in root })
        defer { reopened.shutdown() }
        let current = try await reopened.handle(.read(session: session))
        let saved = try await reopened.handle(.read(session: archive))
        XCTAssertEqual(current.resetID, archive)
        XCTAssertTrue(current.items.isEmpty)
        XCTAssertEqual(saved.items, original.items)
        XCTAssertEqual(saved.project, project)
    }

    func testMultipleProjectsShareOneStoreWithoutCrossingIdentityOrLifecycle() async throws {
        let root = try root(), first = ProjectId(), second = ProjectId()
        let firstFolder = root.appendingPathComponent("one"), secondFolder = root.appendingPathComponent("two")
        for folder in [firstFolder, secondFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let runtime = try AgentRuntimeService(storageDirectory: root.appendingPathComponent("agents"), home: root,
            projectDirectory: { id in
                switch id {
                case first: return firstFolder
                case second: return secondFolder
                default: throw ServiceError(.unknownProject, "Missing project")
                }
            })
        defer { runtime.shutdown() }
        let firstSession = SessionId(), secondSession = SessionId()
        _ = try await runtime.handle(.create(session: firstSession, project: first, provider: .claude))
        _ = try await runtime.handle(.create(session: secondSession, project: second, provider: .codex))
        do {
            _ = try await runtime.handle(.create(session: firstSession, project: second, provider: .claude))
            XCTFail("A session cannot move projects through a repeated create")
        } catch { XCTAssertEqual(agentErrorCode(error), .badRequest) }
        XCTAssertFalse(runtime.tryRefuseIfIdle())
        runtime.close(project: first, directory: firstFolder.path)
        let closed = try await runtime.handle(.read(session: firstSession))
        let open = try await runtime.handle(.read(session: secondSession))
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(open.status, .idle)
        XCTAssertEqual(open.project, second)
        runtime.refuseNewRequests()
        do {
            _ = try await runtime.handle(.create(session: SessionId(), project: second, provider: .codex))
            XCTFail("Shutdown reservation must reject new work")
        } catch {}
    }

    func testStorageOwnershipIsReleasedOnlyAfterShutdown() throws {
        let root = try root()
        let runtime = try AgentRuntimeService(storageDirectory: root, home: root, projectDirectory: { _ in root })
        XCTAssertThrowsError(try AgentRuntimeService(storageDirectory: root, home: root, projectDirectory: { _ in root }))
        runtime.shutdown()
        let reopened = try AgentRuntimeService(storageDirectory: root, home: root, projectDirectory: { _ in root })
        reopened.shutdown()
        reopened.shutdown()
    }
}
