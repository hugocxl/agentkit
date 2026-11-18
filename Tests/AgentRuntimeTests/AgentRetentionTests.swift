import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// A clock tests move forward.
final class AgentTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date()) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var read: @Sendable () -> Date { { [self] in now } }
}

/// A provider that finishes each message at once, or fails it as scripted.
final class AgentScriptedRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let resume: String?
    private let lock = NSLock()
    private var sentTexts: [String] = []
    /// Events sent before the message's turn ends, in place of a plain completion.
    var script: ((String) throws -> [AgentRuntimeEvent])?
    var decisions: [(String, String, [String: [String]]?)] { lock.withLock { recordedDecisions } }
    private var recordedDecisions: [(String, String, [String: [String]]?)] = []
    var sent: [String] { lock.withLock { sentTexts } }

    init(resume: String?, _ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.resume = resume; self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { sentTexts.append(text) }
        callback(.providerSession(resume ?? "provider-thread"))
        if let script {
            for event in try script(text) { callback(event) }
            return
        }
        callback(.item(AgentChatItem(id: UUID().uuidString, kind: .assistant, text: "Done: " + text)))
        callback(.status(.idle))
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?, attachments: [StagedAgentAttachment]) async throws {
        try await send(text: text, model: model, reasoningEffort: reasoningEffort)
    }
    func approve(request: String, allow: Bool) async throws { callback(.status(.working)) }
    func decide(request: String, decision: String, answers: [String: [String]]?) async throws {
        lock.withLock { recordedDecisions.append((request, decision, answers)) }
        callback(.item(AgentChatItem(id: request, kind: .approval, text: "Decided " + decision)))
        callback(.status(.working))
    }
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

/// Hands out the scripted runtime each conversation starts.
final class AgentScriptedRuntimes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [AgentScriptedRuntime] = []
    var script: ((String) throws -> [AgentRuntimeEvent])?
    var all: [AgentScriptedRuntime] { lock.withLock { made } }
    var last: AgentScriptedRuntime? { all.last }
    var factory: AgentSessions.Factory {
        { [self] _, _, resume, callback in
            let runtime = AgentScriptedRuntime(resume: resume, callback)
            runtime.script = script
            lock.withLock { made.append(runtime) }
            return runtime
        }
    }
}

final class AgentRetentionTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-l1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func settle(_ sessions: AgentSessions, _ id: SessionId, until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<500 {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    private func open(_ root: URL, repo: GitTestRepo, clock: AgentTestClock, runtimes: AgentScriptedRuntimes,
                      retention: AgentConversationRetention = .keepClosed,
                      cleanups: [AgentDeletionCleanup] = []) throws -> AgentSessions {
        try AgentSessions(root: root, projectDirectory: { _ in repo.path }, retention: retention, now: clock.read,
                          deletionCleanups: cleanups, factory: runtimes.factory)
    }

    /// A conversation with one finished turn: an attachment, a checkpoint and a provider thread.
    private func converse(_ sessions: AgentSessions, repo: GitTestRepo, text: String) async throws -> (SessionId, AgentChatSnapshot) {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        try repo.write("notes-\(id).txt", "before\n")
        let note = AgentChatAttachment(name: "note.txt", mimeType: "text/plain", data: Data("attached \(text)".utf8))
        _ = try await sessions.handle(.send(session: id, text: text, model: nil, attachments: [note]))
        let done = try await settle(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        return (id, done)
    }

    func testClosedAndArchivedConversationsSurviveThirtyDaysAndReopenWithTheirResources() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        var sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        let (closedID, closedBefore) = try await converse(sessions, repo: repo, text: "first")
        let (archivedID, _) = try await converse(sessions, repo: repo, text: "second")
        _ = try await sessions.handle(.close(session: closedID))
        guard case .snapshot(let archived) = try await sessions.library(.archive(session: archivedID)) else { return XCTFail() }
        XCTAssertEqual(archived.status, .closed)
        sessions.shutdown()

        // An existing store opened again, past the old implicit 30 days, under the default.
        clock.advance(31 * 86_400)
        sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        guard case .list(let kept) = try await sessions.library(.list(project: nil)) else { return XCTFail() }
        XCTAssertEqual(Set(kept.map(\.session)), [closedID, archivedID])
        XCTAssertTrue(kept.allSatisfy { $0.expiresAt == nil && $0.origin == .closed })
        XCTAssertEqual(kept.first { $0.session == closedID }?.title, "first")
        sessions.shutdown()

        sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        defer { sessions.shutdown() }
        guard case .snapshot(let reopened) = try await sessions.library(.reopen(session: closedID)) else { return XCTFail() }
        XCTAssertEqual(reopened.session, closedID)
        XCTAssertEqual(reopened.status, .idle)
        XCTAssertEqual(reopened.providerSession, closedBefore.providerSession)
        let checkpoint = try XCTUnwrap(reopened.turns?.first?.checkpoint)
        let reply = try await sessions.checkpoint(.init(session: closedID, checkpoint: checkpoint.id))
        XCTAssertEqual(reply.checkpoint, checkpoint.id)
        let user = try XCTUnwrap(reopened.items.first { $0.kind == .user })
        let descriptor = try XCTUnwrap(user.attachments?.first)
        let attachment = try await sessions.attachment(.init(session: closedID, item: user.id, attachment: descriptor.id))
        XCTAssertEqual(attachment.attachment.data, Data("attached first".utf8))
        // It carries on its provider thread.
        _ = try await sessions.handle(.send(session: closedID, text: "again", model: nil))
        _ = try await settle(sessions, closedID) { $0.status == .idle && $0.items.contains { $0.text == "Done: again" } }
        XCTAssertEqual(runtimes.last?.resume, closedBefore.providerSession)
        guard case .list(let remaining) = try await sessions.library(.list(project: nil)) else { return XCTFail() }
        XCTAssertEqual(remaining.map(\.session), [archivedID])
    }

    func testRetentionIsTheHostsChoiceAndLegacyRecordsAgeFromTheirLastChange() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        let month: TimeInterval = 30 * 86_400
        var sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        let recent = SessionId(), old = SessionId(), legacy = SessionId(), live = SessionId()
        for id in [recent, old, legacy, live] { _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude)) }
        _ = try await sessions.handle(.close(session: old))
        _ = try await sessions.handle(.close(session: legacy))
        clock.advance(20 * 86_400)
        _ = try await sessions.handle(.close(session: recent))
        sessions.shutdown()
        // A record saved before close times were kept: its age is its last change.
        let legacyRecord = root.appendingPathComponent(legacy.description + ".json")
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyRecord)) as? [String: Any])
        XCTAssertNotNil(saved["closedAt"])
        saved["closedAt"] = nil
        try JSONSerialization.data(withJSONObject: saved).write(to: legacyRecord)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: legacyRecord.path)

        clock.advance(15 * 86_400)
        sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes, retention: .deleteClosed(after: month))
        guard case .list(let kept) = try await sessions.library(.list(project: nil)) else { return XCTFail() }
        XCTAssertEqual(kept.map(\.session), [recent], "Closed 35 days and an older legacy record go; 15 days stays")
        XCTAssertEqual(kept.first?.expiresAt, kept.first?.closedAt?.addingTimeInterval(month))
        _ = try await sessions.handle(.read(session: live))
        sessions.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRecord.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(old.description + ".json").path))
    }

    func testDeleteRemovesOnlyTheSelectedChatAndKeepsCheckpointsAnArchiveShares() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        let deleted = Recorded()
        let sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes, cleanups: [{ deleted.append($0) }])
        defer { sessions.shutdown() }
        let notified = Recorded()
        sessions.conversationDeleted = { notified.append($0) }
        let (live, _) = try await converse(sessions, repo: repo, text: "cleared")
        let (other, _) = try await converse(sessions, repo: repo, text: "other")
        // Clearing in place leaves an archive holding the turn's checkpoint.
        let archive = SessionId()
        let state = try await sessions.handle(.read(session: live))
        _ = try await sessions.handle(.clear(session: live, archive: archive, expectedRevision: state.revision))
        let archived = try await sessions.handle(.read(session: archive))
        let checkpointID = try XCTUnwrap(archived.turns?.first?.checkpoint?.id)
        let archiveRecord = root.appendingPathComponent("checkpoints/\(archive)/\(checkpointID).json")
        let pins = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: archiveRecord))
        // Another conversation's record references the same refs, as a copy kept by a reopened archive.
        let otherFolder = root.appendingPathComponent("checkpoints/\(other)", isDirectory: true)
        try FileManager.default.copyItem(at: archiveRecord, to: otherFolder.appendingPathComponent("shared.json"))

        // Only a closed conversation, and only with the confirmation, can be deleted.
        do {
            _ = try await sessions.library(.delete(session: other, confirmation: AgentConversationLibraryRequest.deleteConfirmation(for: other)))
            XCTFail("An open conversation can't be deleted")
        } catch {}
        do {
            _ = try await sessions.library(.delete(session: archive, confirmation: "yes"))
            XCTFail("A delete needs its confirmation")
        } catch {}
        guard case .deleted(let gone) = try await sessions.library(.delete(session: archive,
            confirmation: AgentConversationLibraryRequest.deleteConfirmation(for: archive))) else { return XCTFail() }
        XCTAssertEqual(gone, archive)
        sessions.drainCallbacks()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(archive.description + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("checkpoints/\(archive)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/\(archive)").path))
        XCTAssertTrue([pins.before, pins.after].allSatisfy { (try? repo.run("rev-parse", "--verify", "--quiet", $0.reference)) != nil },
                      "Refs another conversation's record pins stay")
        XCTAssertEqual(deleted.values, [archive])
        XCTAssertEqual(notified.values, [archive])
        do { _ = try await sessions.handle(.read(session: archive)); XCTFail("Deleted") } catch {}
        // Everything else is untouched.
        _ = try await sessions.handle(.read(session: live))
        let kept = try await sessions.handle(.read(session: other))
        XCTAssertNotNil(kept.turns?.first?.checkpoint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("attachments/\(other)").path))
    }

    func testDeletingAConversationNoOneSharesRemovesItsRefs() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        let sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        defer { sessions.shutdown() }
        let (id, done) = try await converse(sessions, repo: repo, text: "alone")
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        let record = try JSONDecoder().decode(AgentCheckpointRecord.self,
            from: Data(contentsOf: root.appendingPathComponent("checkpoints/\(id)/\(checkpoint).json")))
        _ = try await sessions.handle(.close(session: id))
        _ = try await sessions.library(.delete(session: id, confirmation: AgentConversationLibraryRequest.deleteConfirmation(for: id)))
        XCTAssertTrue([record.before, record.after].allSatisfy { (try? repo.run("rev-parse", "--verify", "--quiet", $0.reference)) == nil })
    }

    func testReopenKeepsUncertainDeliveriesPausedAndTheLedgerRefusesReplays() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        runtimes.script = { text in
            guard text == "maybe" else { return [.status(.idle)] }
            throw AgentRuntimeError("The connection dropped")
        }
        var sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let prompt = AgentPrompt(text: "maybe", model: nil, effort: nil, provider: .codex, planMode: false)
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        let uncertain = try await settle(sessions, id) { $0.queuedPrompts?.first?.state == .uncertain }
        XCTAssertEqual(uncertain.queuePaused, true)
        let closed = try await sessions.handle(.close(session: id))
        XCTAssertEqual(closed.queuedPrompts?.map(\.id), [prompt.id], "A delivery that may have happened stays for review")
        sessions.shutdown()

        sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        defer { sessions.shutdown() }
        guard case .snapshot(let reopened) = try await sessions.library(.reopen(session: id)) else { return XCTFail() }
        XCTAssertEqual(reopened.queuePaused, true)
        XCTAssertEqual(reopened.queuedPrompts?.first?.state, .uncertain)
        let sentBefore = runtimes.all.flatMap(\.sent).count
        _ = try await sessions.handle(.submit(session: id, prompt: prompt))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtimes.all.flatMap(\.sent).count, sentBefore, "The ledger refuses to send it again")
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.queuedPrompts?.count, 1)
    }

    func testArchiveRefusesActiveWork() async throws {
        let root = try temporary(), repo = try GitTestRepo(commit: true), clock = AgentTestClock(), runtimes = AgentScriptedRuntimes()
        runtimes.script = { _ in [] } // The turn keeps working.
        let sessions = try open(root, repo: repo, clock: clock, runtimes: runtimes)
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "work", model: nil))
        do {
            _ = try await sessions.library(.archive(session: id))
            XCTFail("Archiving stops nothing")
        } catch {}
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.status, .working)
    }
}

final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SessionId] = []
    var values: [SessionId] { lock.withLock { list } }
    func append(_ id: SessionId) { lock.withLock { list.append(id) } }
}
