import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

final class AgentRateLimitRecoveryTests: XCTestCase {
    private let clock = AgentTestClock()
    private let runtimes = AgentScriptedRuntimes()
    private var root: URL!
    private var repo: GitTestRepo!
    private var reset = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-l4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = try GitTestRepo(commit: true)
        reset = clock.now.addingTimeInterval(3600)
        let reset = reset
        let limited = Limited()
        // The first message meets the usage limit, as Claude's rejected rate_limit_event and
        // Codex's rateLimits update are followed by the turn's failure; later ones finish.
        runtimes.script = { text in
            guard text == "build it", limited.first() else { return [.status(.idle)] }
            return [.activity(AgentChatActivity(kind: .rateLimited, resumesAt: reset, message: "Usage limit reached")),
                    .failure("You've hit your usage limit."), .status(.failed)]
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func open() throws -> AgentSessions {
        let sessions = try AgentSessions(root: root, projectDirectory: { [repo] _ in repo?.path ?? "/" }, now: clock.read, factory: runtimes.factory)
        sessions.capturesCheckpoints = false
        return sessions
    }

    private var deliveries: Int { runtimes.all.flatMap(\.sent).filter { $0 == "build it" }.count }

    private func limitedConversation(_ sessions: AgentSessions) async throws -> (SessionId, String) {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let note = AgentChatAttachment(name: "spec.txt", mimeType: "text/plain", data: Data("spec".utf8))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "build it", model: nil, effort: nil,
                                                                             provider: .codex, planMode: false, attachments: [note])))
        let failed = try await settle(sessions, id) { $0.turns?.last?.rateLimit != nil && $0.status == .failed }
        return (id, try XCTUnwrap(failed.turns?.last?.userItemID))
    }

    private func settle(_ sessions: AgentSessions, _ id: SessionId, until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<500 {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    func testTheLimitAndItsResetStayOnTheTurnThroughReconnectAndRestart() async throws {
        var sessions = try open()
        let (id, turn) = try await limitedConversation(sessions)
        // A reconnecting client reads it again.
        let read = try await sessions.handle(.read(session: id))
        let limit = try XCTUnwrap(read.turns?.last?.rateLimit)
        XCTAssertEqual(limit.resetsAt, reset)
        XCTAssertEqual(limit.retryPromptID, AgentTurnRateLimit.retryPromptID(session: id, turn: turn))
        XCTAssertNil(read.activity, "The live activity ends with the turn; the turn keeps the limit")
        XCTAssertTrue(read.items.contains { $0.id == turn && $0.text == "build it" }, "The prompt is retained")
        try read.validate()
        sessions.shutdown()
        sessions = try open()
        defer { sessions.shutdown() }
        let restored = try await sessions.handle(.read(session: id))
        XCTAssertEqual(restored.turns?.first(where: { $0.userItemID == turn })?.rateLimit?.resetsAt, reset)
    }

    func testAManualRetrySendsThePromptOnceEvenWhenRepeated() async throws {
        let sessions = try open()
        defer { sessions.shutdown() }
        let (id, turn) = try await limitedConversation(sessions)
        XCTAssertEqual(deliveries, 1)
        async let first = sessions.handle(.retryTurn(session: id, turn: turn))
        async let second = sessions.handle(.retryTurn(session: id, turn: turn))
        _ = try await (first, second)
        let done = try await settle(sessions, id) { $0.status == .idle && $0.queuedPrompts?.isEmpty != false }
        XCTAssertEqual(deliveries, 2, "One retry, however many times it is asked")
        XCTAssertEqual(done.turns?.first(where: { $0.userItemID == turn })?.rateLimit?.retried, true)
        let resent = try XCTUnwrap(done.items.last { $0.kind == .user })
        XCTAssertEqual(resent.attachments?.map(\.name), ["spec.txt"], "Its attachments go again")
        _ = try await sessions.handle(.retryTurn(session: id, turn: turn))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveries, 2)
    }

    func testACancelledScheduleSendsNothing() async throws {
        var sessions = try open()
        let (id, turn) = try await limitedConversation(sessions)
        let scheduled = try await sessions.handle(.scheduleRetry(session: id, turn: turn, enabled: true))
        XCTAssertEqual(scheduled.turns?.last?.rateLimit?.retryAt, reset)
        let cancelled = try await sessions.handle(.scheduleRetry(session: id, turn: turn, enabled: false))
        XCTAssertNil(cancelled.turns?.last?.rateLimit?.retryAt)
        sessions.shutdown()
        clock.advance(7200)
        sessions = try open()
        defer { sessions.shutdown() }
        await sessions.fireDueRetries()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveries, 1)
    }

    func testAScheduledRetryPersistsAndFiresOnceWhenItRacesAManualRetryAfterReconnect() async throws {
        var sessions = try open()
        let (id, turn) = try await limitedConversation(sessions)
        _ = try await sessions.handle(.scheduleRetry(session: id, turn: turn, enabled: true))
        sessions.shutdown()
        // Not due yet: a restart keeps the schedule and sends nothing.
        sessions = try open()
        await sessions.fireDueRetries()
        XCTAssertEqual(deliveries, 1)
        let kept = try await sessions.handle(.read(session: id))
        XCTAssertEqual(kept.turns?.last?.rateLimit?.retryAt, reset)
        clock.advance(3601)
        // The schedule fires as a reconnected client retries by hand.
        let racing = sessions
        async let manual = racing.handle(.retryTurn(session: id, turn: turn))
        async let scheduled: Void = racing.fireDueRetries()
        _ = try await (manual, scheduled)
        let done = try await settle(sessions, id) { $0.status == .idle && $0.queuedPrompts?.isEmpty != false }
        XCTAssertEqual(deliveries, 2)
        XCTAssertNil(done.turns?.first(where: { $0.userItemID == turn })?.rateLimit?.retryAt)
        sessions.shutdown()
        sessions = try open()
        defer { sessions.shutdown() }
        await sessions.fireDueRetries()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveries, 2)
    }

    func testScheduleNeedsAKnownReset() async throws {
        runtimes.script = { _ in [.activity(AgentChatActivity(kind: .rateLimited, message: "Usage limit reached")), .failure("limit"), .status(.failed)] }
        let sessions = try open()
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "go", model: nil))
        let failed = try await settle(sessions, id) { $0.turns?.last?.rateLimit != nil }
        let turn = try XCTUnwrap(failed.turns?.last?.userItemID)
        XCTAssertNil(failed.turns?.last?.rateLimit?.resetsAt)
        do {
            _ = try await sessions.handle(.scheduleRetry(session: id, turn: turn, enabled: true))
            XCTFail("No reset time, no schedule")
        } catch {}
    }

    func testCodexUsageLimitShapesBecomeTheTurnsLimit() throws {
        let events = Events()
        let runtime = AgentRuntime(provider: .codex, directory: "/", resumeSession: nil, onEvent: { events.append($0) })
        // `account/rateLimits/updated` and the failing `error`, as codex-cli 0.170.0's schema defines them.
        runtime.replay(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1795424207},"secondary":{"usedPercent":40,"resetsAt":1795000000},"rateLimitReachedType":"rate_limit_reached"}}}"#)
        let limited = events.values.compactMap { event -> AgentChatActivity? in
            if case .activity(let activity) = event { return activity } else { return nil }
        }
        XCTAssertEqual(limited.last?.kind, .rateLimited)
        XCTAssertEqual(limited.last?.resumesAt, Date(timeIntervalSince1970: 1_795_424_207))
    }
}

private final class Limited: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AgentRuntimeEvent] = []
    var values: [AgentRuntimeEvent] { lock.withLock { list } }
    func append(_ event: AgentRuntimeEvent) { lock.withLock { list.append(event) } }
}
