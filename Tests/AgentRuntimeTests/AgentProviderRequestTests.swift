import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

/// Codex server requests replayed in the shapes codex-cli 0.170.0's generated app-server schema
/// defines (`codex app-server generate-json-schema`, stable and `--experimental`). They are
/// schema-conformant fixtures, not captured traffic.
final class AgentProviderRequestTests: XCTestCase {
    private static let handshake = """
    take
    emit '{"id":1,"result":{}}'
    take
    take
    emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
    take
    emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
    """

    private func waitFor(_ recorder: AgentRuntimeRecorder, _ ids: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            let transcript = recorder.transcript
            if ids.allSatisfy({ transcript[$0] != nil }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Requests \(ids) never arrived", file: file, line: line)
    }

    private func responses(_ fixture: AgentRuntimeFixture, count: Int) async throws -> [[String: Any]] {
        for _ in 0..<300 {
            let messages = try fixture.messages().filter { $0["method"] == nil && ($0["result"] != nil || $0["error"] != nil) }
            if messages.count >= count { return messages }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try fixture.messages().filter { $0["method"] == nil }
    }

    func testPermissionsAndElicitationsKeepProviderIDsAndSendTheOfferedDecisions() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture(Self.handshake + #"""

        emit '{"id":7,"method":"item/permissions/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"perm-1","startedAtMs":1795424000000,"cwd":"/repo","reason":"Needs the build cache","permissions":{"fileSystem":{"read":["/cache"],"write":["/repo/.build"]},"network":{"enabled":true}}}}'
        emit '{"id":"7","method":"mcpServer/elicitation/request","params":{"threadId":"thread","turnId":"turn","serverName":"tickets","mode":"form","message":"Fill in the ticket","requestedSchema":{"type":"object","required":["name","count"],"properties":{"name":{"type":"string","title":"Name"},"count":{"type":"integer","title":"Count"},"colors":{"type":"array","items":{"type":"string","enum":["red","blue"]}},"agree":{"type":"boolean","title":"Agree"},"tier":{"type":"string","oneOf":[{"const":"p","title":"Pro"},{"const":"f","title":"Free"}]}}}}}'
        emit '{"id":8,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"cmd-1","startedAtMs":1795424000000,"command":"rm -rf build","cwd":"/repo","availableDecisions":["cancel"]}}'
        emit '{"id":9,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"cmd-2","startedAtMs":1795424000000,"command":"make","availableDecisions":["acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["make"]}},"decline"]}}'
        emit '{"id":"x9","method":"item/fileChange/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"patch-1","startedAtMs":1795424000000,"reason":"write","grantRoot":null}}'
        emit '{"method":"serverRequest/resolved","params":{"threadId":"thread","requestId":"x9"}}'
        take
        take
        take
        take
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Go", model: nil)
        try await waitFor(recorder, ["7", "str:7", "8", "9", "x9"])
        var transcript = recorder.transcript

        // A numeric and a string ID that read alike stay two requests, each with its own ID.
        let permission = try XCTUnwrap(transcript["7"]?.interaction)
        XCTAssertEqual(permission.providerRequestID, .number(7))
        XCTAssertEqual(permission.decisions.map(\.id), ["turn", "session", "decline"])
        XCTAssertEqual(permission.requested, ["Read /cache", "Write /repo/.build", "Network access"])
        XCTAssertEqual(permission.scope, "Working in /repo")
        let form = try XCTUnwrap(transcript["str:7"])
        XCTAssertEqual(form.interaction?.providerRequestID, .string("7"))
        XCTAssertEqual(form.questionnaire?.questions.map(\.id), ["agree", "colors", "count", "name", "tier"])
        XCTAssertEqual(form.questionnaire?.questions.first { $0.id == "tier" }?.options.map(\.label), ["Pro", "Free"])
        XCTAssertEqual(form.interaction?.decisions.map(\.kind), [.submit, .decline, .cancel])
        // Only what the provider offered: a cancel-only request, and one without one-time acceptance.
        XCTAssertEqual(transcript["8"]?.interaction?.decisions.map(\.id), ["cancel"])
        XCTAssertNil(transcript["8"]?.interaction?.only(.allowOnce))
        XCTAssertNil(transcript["8"]?.interaction?.only(.decline))
        XCTAssertEqual(transcript["9"]?.interaction?.decisions.map(\.kind), [.allowSession, .allowAlways, .decline])
        XCTAssertNil(transcript["9"]?.interaction?.only(.allowOnce))
        // Settled by the provider before anyone answered.
        XCTAssertEqual(transcript["x9"]?.interaction?.outcome, .resolvedElsewhere)
        XCTAssertEqual(transcript["x9"]?.isComplete, true)
        do { try await runtime.decide(request: "x9", decision: "accept", answers: nil); XCTFail("Resolved elsewhere") } catch {}

        do { try await runtime.approve(request: "9", allow: true); XCTFail("No one-time acceptance was offered") } catch {}
        try await runtime.decide(request: "7", decision: "session", answers: nil)
        do {
            try await runtime.decide(request: "str:7", decision: "accept", answers: ["name": ["Ada"], "count": ["three"]])
            XCTFail("A count must be a number")
        } catch {}
        try await runtime.decide(request: "str:7", decision: "accept",
                                 answers: ["name": ["Ada"], "count": ["3"], "colors": ["red", "blue"], "agree": ["Yes"], "tier": ["Pro"]])
        try await runtime.decide(request: "8", decision: "cancel", answers: nil)
        try await runtime.decide(request: "9", decision: "acceptWithExecpolicyAmendment", answers: nil)
        // The same decision again, as after a lost reply, sends nothing more.
        try await runtime.decide(request: "9", decision: "acceptWithExecpolicyAmendment", answers: nil)

        let sent = try await responses(fixture, count: 4)
        XCTAssertEqual(sent.count, 4)
        let grant = try XCTUnwrap(sent.first { $0["id"] as? Int == 7 }?["result"] as? [String: Any])
        XCTAssertEqual(grant["scope"] as? String, "session")
        XCTAssertEqual(((grant["permissions"] as? [String: Any])?["network"] as? [String: Any])?["enabled"] as? Bool, true)
        let answer = try XCTUnwrap(sent.first { $0["id"] as? String == "7" }?["result"] as? [String: Any])
        XCTAssertEqual(answer["action"] as? String, "accept")
        let content = try XCTUnwrap(answer["content"] as? [String: Any])
        XCTAssertEqual(content["name"] as? String, "Ada")
        XCTAssertEqual(content["count"] as? Int, 3)
        XCTAssertEqual(content["colors"] as? [String], ["red", "blue"])
        XCTAssertEqual(content["agree"] as? Bool, true)
        XCTAssertEqual(content["tier"] as? String, "p")
        XCTAssertEqual((sent.first { $0["id"] as? Int == 8 }?["result"] as? [String: Any])?["decision"] as? String, "cancel")
        let amendment = (sent.first { $0["id"] as? Int == 9 }?["result"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual((amendment?["acceptWithExecpolicyAmendment"] as? [String: Any])?["execpolicy_amendment"] as? [String], ["make"])

        // The cards and history agree with what was sent.
        transcript = recorder.transcript
        XCTAssertEqual(transcript["7"]?.interaction?.chosen, "session")
        XCTAssertEqual(transcript["7"]?.text, "Approved for the session")
        XCTAssertEqual(transcript["8"]?.interaction?.chosen, "cancel")
        XCTAssertEqual(transcript["8"]?.text, "Declined and stopped")
        XCTAssertEqual(transcript["9"]?.interaction?.outcome, .decided)
        XCTAssertEqual(transcript["str:7"]?.text, "Submitted")
    }

    func testElicitationDeclineCancelRejectionAndDisconnect() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture(Self.handshake + #"""

        emit '{"id":11,"method":"mcpServer/elicitation/request","params":{"threadId":"thread","turnId":"turn","serverName":"github","mode":"form","message":"Allow github to run create_issue?","requestedSchema":{"type":"object","properties":{}}}}'
        emit '{"id":12,"method":"mcpServer/elicitation/request","params":{"threadId":"thread","turnId":null,"serverName":"auth","mode":"url","message":"Sign in","url":"https://example.invalid/login","elicitationId":"e1"}}'
        emit '{"id":13,"method":"mcpServer/elicitation/request","params":{"threadId":"thread","serverName":"odd","mode":"openai/form","message":"Custom","requestedSchema":{"anything":true}}}'
        emit '{"id":14,"method":"mcpServer/elicitation/request","params":{"threadId":"thread","serverName":"notes","mode":"form","message":"Title?","requestedSchema":{"type":"object","properties":{"title":{"type":"string"}}}}}'
        emit '{"id":15,"method":"mcpServer/elicitation/request","params":{"threadId":"thread","serverName":"notes","mode":"form","message":"Later","requestedSchema":{"type":"object","properties":{"title":{"type":"string"}}}}}'
        take
        take
        take
        take
        hold
        """#)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        try await runtime.send(text: "Go", model: nil)
        try await waitFor(recorder, ["11", "14", "15"])
        let approval = try XCTUnwrap(recorder.transcript["11"])
        XCTAssertNil(approval.questionnaire, "An empty form is an approval")
        XCTAssertEqual(approval.interaction?.decisions.map(\.id), ["accept", "decline", "cancel"])
        XCTAssertEqual(approval.interaction?.scope, "MCP server github")
        try await runtime.decide(request: "11", decision: "decline", answers: nil)
        try await runtime.answer(request: "14", answers: [:], cancelled: true)
        let sent = try await responses(fixture, count: 4)
        let byID = Dictionary(sent.compactMap { message in (message["id"] as? Int).map { ($0, message) } }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual((byID[11]?["result"] as? [String: Any])?["action"] as? String, "decline")
        XCTAssertTrue((byID[11]?["result"] as? [String: Any])?["content"] is NSNull)
        XCTAssertEqual((byID[14]?["result"] as? [String: Any])?["action"] as? String, "cancel")
        // Unsupported shapes are refused explicitly, never answered as if the user had.
        for id in [12, 13] {
            XCTAssertEqual((byID[id]?["error"] as? [String: Any])?["code"] as? Int, -32602)
            XCTAssertNil(byID[id]?["result"])
        }
        XCTAssertNil(recorder.transcript["12"])
        // The provider goes away with a request pending: it ends unanswered.
        runtime.stop()
        XCTAssertEqual(recorder.transcript["15"]?.interaction?.outcome, .ended)
        XCTAssertEqual(recorder.transcript["15"]?.isComplete, true)
        do { try await runtime.decide(request: "15", decision: "accept", answers: ["title": ["x"]]); XCTFail("Gone") } catch {}
    }

    /// Overlapping parent and child requests; one child ends before its request is answered.
    func testChildRequestsKeepTheirOriginAndExpireWithTheirChild() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture(Self.handshake + #"""

        emit '{"method":"item/started","params":{"threadId":"thread","turnId":"turn","startedAtMs":1795424000000,"item":{"type":"collabAgentToolCall","id":"spawn-1","tool":"spawnAgent","status":"inProgress","senderThreadId":"thread","receiverThreadIds":["child-a","child-b"],"agentsStates":{"child-a":{"status":"running"},"child-b":{"status":"running"}}}}}'
        emit '{"id":20,"method":"item/commandExecution/requestApproval","params":{"threadId":"child-a","turnId":"child-a-turn","itemId":"a-cmd","startedAtMs":1795424000000,"command":"npm test"}}'
        emit '{"id":21,"method":"item/commandExecution/requestApproval","params":{"threadId":"child-b","turnId":"child-b-turn","itemId":"b-cmd","startedAtMs":1795424000000,"command":"swift build"}}'
        emit '{"id":22,"method":"item/fileChange/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"p-patch","startedAtMs":1795424000000,"reason":"edit"}}'
        emit '{"method":"item/completed","params":{"threadId":"thread","turnId":"turn","completedAtMs":1795424001000,"item":{"type":"collabAgentToolCall","id":"spawn-1","tool":"wait","status":"completed","senderThreadId":"thread","receiverThreadIds":["child-a","child-b"],"agentsStates":{"child-a":{"status":"completed","message":"done"},"child-b":{"status":"running"}}}}}'
        take
        take
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Go", model: nil)
        try await waitFor(recorder, ["20", "21", "22"])
        for _ in 0..<300 where recorder.transcript["20"]?.isComplete != true { try await Task.sleep(for: .milliseconds(10)) }
        let transcript = recorder.transcript
        XCTAssertEqual(transcript["20"]?.interaction?.outcome, .expired)
        XCTAssertEqual(transcript["21"]?.interaction?.origin, AgentRequestOrigin(threadID: "child-b", agentID: "child-b", toolUseID: "spawn-1"))
        XCTAssertNil(transcript["22"]?.interaction?.origin, "The parent's own request")
        do { try await runtime.decide(request: "20", decision: "accept", answers: nil); XCTFail("Expired") } catch {}
        try await runtime.decide(request: "21", decision: "accept", answers: nil)
        try await runtime.decide(request: "22", decision: "decline", answers: nil)
        let sent = try await responses(fixture, count: 2)
        XCTAssertEqual(sent.compactMap { $0["id"] as? Int }.sorted(), [21, 22], "Nothing goes to the ended child; each answer reaches its requester")
        XCTAssertEqual((sent.first { $0["id"] as? Int == 21 }?["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertEqual((sent.first { $0["id"] as? Int == 22 }?["result"] as? [String: Any])?["decision"] as? String, "decline")
    }

    /// Claude 2.1.311's `can_use_tool` names the subagent that asks in `agent_id`, as its
    /// bundled source shows; this replay is written from that source, not captured.
    func testClaudeSubagentApprovalNamesItsAgent() throws {
        let events = Events()
        let runtime = AgentRuntime(provider: .claude, directory: "/", resumeSession: nil, onEvent: { events.append($0) })
        runtime.replay(#"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1","agent_id":"agent-7"}}"#)
        runtime.replay(#"{"type":"control_request","request_id":"req-2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"},"tool_use_id":"toolu_2"}}"#)
        let items = events.values.compactMap { event -> AgentChatItem? in if case .item(let item) = event { return item } else { return nil } }
        XCTAssertEqual(items.first { $0.id == "req-1" }?.interaction?.origin?.agentID, "agent-7")
        XCTAssertEqual(items.first { $0.id == "req-1" }?.interaction?.decisions.map(\.id), ["allow", "allowAlways", "deny"])
        XCTAssertNil(items.first { $0.id == "req-2" }?.interaction, "The conversation's own agent keeps plain Allow and Deny")
    }

    func testRequestKeysNeverCollide() {
        XCTAssertEqual(agentProviderRequestKey(7), "7")
        XCTAssertEqual(agentProviderRequestKey("7"), "str:7")
        XCTAssertEqual(agentProviderRequestKey("str:7"), "str:str:7")
        XCTAssertEqual(agentProviderRequestKey("abc"), "abc")
    }
}

final class AgentSessionDecisionTests: XCTestCase {
    func testDecisionsAreCheckedAgainstTheOfferAndARepeatAfterALostReplyChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-l3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimes = AgentScriptedRuntimes()
        let offer = AgentApprovalRequest(method: "item/commandExecution/requestApproval", providerRequestID: .number(4), summary: "make",
            decisions: [.init(id: "acceptForSession", kind: .allowSession, label: "Allow for session"), .init(id: "cancel", kind: .cancel, label: "Decline and stop")],
            origin: AgentRequestOrigin(threadID: "child", agentID: "child", toolUseID: "spawn"))
        runtimes.script = { _ in
            [.item(AgentChatItem(id: "4", kind: .approval, text: "make", isComplete: false, interaction: offer)), .status(.waiting)]
        }
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: runtimes.factory)
        sessions.capturesCheckpoints = false
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "go", model: nil))
        var waiting = try await sessions.handle(.read(session: id))
        for _ in 0..<300 where waiting.status != .waiting {
            try await Task.sleep(for: .milliseconds(10))
            waiting = try await sessions.handle(.read(session: id))
        }
        XCTAssertEqual(waiting.items.first { $0.id == "4" }?.interaction, offer, "The offer reaches clients whole")
        try waiting.validate()
        do {
            _ = try await sessions.handle(.decide(session: id, request: "4", decision: "accept"))
            XCTFail("Accept wasn't offered")
        } catch {}
        _ = try await sessions.handle(.decide(session: id, request: "4", decision: "acceptForSession"))
        // The scripted provider records the decision and settles the card.
        XCTAssertEqual(runtimes.last?.decisions.map(\.1), ["acceptForSession"])
        var settled = try await sessions.handle(.read(session: id))
        // Stand in for the runtime's settled card, as `finishDecision` records it.
        runtimes.last?.callback(.item(AgentChatItem(id: "4", kind: .approval, text: "Approved for the session",
            interaction: { var done = offer; done.chosen = "acceptForSession"; done.outcome = .decided; return done }())))
        for _ in 0..<300 where settled.items.first(where: { $0.id == "4" })?.interaction?.chosen == nil {
            try await Task.sleep(for: .milliseconds(10))
            settled = try await sessions.handle(.read(session: id))
        }
        _ = try await sessions.handle(.decide(session: id, request: "4", decision: "acceptForSession"))
        XCTAssertEqual(runtimes.last?.decisions.count, 1, "A repeat after a lost reply sends nothing")
        do {
            _ = try await sessions.handle(.decide(session: id, request: "4", decision: "cancel"))
            XCTFail("A settled request takes no other decision")
        } catch {}
    }
}
