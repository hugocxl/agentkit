import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

final class AgentApplicationToolsTests: XCTestCase {
    private let definition = AgentToolDefinition(name: "edit", description: "An undoable application edit",
        inputSchema: ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]])

    func testClaudeDiscoversCallsAndDeduplicatesApplicationTools() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_request","request_id":"list","request":{"subtype":"mcp_message","server_name":"agentkit","message":{"jsonrpc":"2.0","id":1,"method":"tools/list"}}}'
        take
        emit '{"type":"control_request","request_id":"call","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"edit","arguments":{"value":"one"},"_meta":{"claudecode/toolUseId":"edit-1"}}}}}'
        take
        emit '{"type":"control_request","request_id":"retry","request":{"subtype":"mcp_message","message":{"id":3,"method":"tools/call","params":{"name":"edit","arguments":{"value":"one"},"_meta":{"claudecode/toolUseId":"edit-1"}}}}}'
        take
        emit '{"type":"control_request","request_id":"shell","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch forbidden"}}}'
        take
        emit '{"type":"result","subtype":"success","result":"Done"}'
        hold
        """)
        defer { fixture.remove() }
        let calls = ToolCalls(), recorder = AgentRuntimeRecorder()
        let completed = expectation(description: "finished")
        recorder.observe = { if case .status(.idle) = $0 { completed.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init([definition]) { call in
            await calls.append(call)
            return .init(text: "Edited", images: [.init(name: "frame.png", mimeType: "image/png", data: Data([1, 2, 3]))])
        })
        defer { runtime.stop() }
        try await runtime.setAccess(.fullAccess)
        try await runtime.send(text: "edit", model: nil)
        await fulfillment(of: [completed], timeout: 5)
        let count = await calls.count
        XCTAssertEqual(count, 1)
        let sent = try fixture.messages()
        let initialize = try XCTUnwrap(sent.first?["request"] as? [String: Any])
        XCTAssertEqual(initialize["sdkMcpServers"] as? [String], ["agentkit"])
        let list = try XCTUnwrap((sent[2]["response"] as? [String: Any])?["response"] as? [String: Any])
        let mcp = try XCTUnwrap(list["mcp_response"] as? [String: Any])
        XCTAssertEqual(((mcp["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String, "edit")
        for index in [3, 4] {
            let response = try XCTUnwrap((sent[index]["response"] as? [String: Any])?["response"] as? [String: Any])
            let payload = try XCTUnwrap((response["mcp_response"] as? [String: Any])?["result"] as? [String: Any])
            XCTAssertEqual((payload["content"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(payload["isError"] as? Bool, false)
        }
        let permission = (sent[5]["response"] as? [String: Any])?["response"] as? [String: Any]
        XCTAssertEqual(permission?["behavior"] as? String, "deny")
        XCTAssertEqual(recorder.transcript["edit-1"]?.tool?.status, .completed)
        XCTAssertEqual(recorder.transcript["edit-1"]?.attachments?.count, 1)
        XCTAssertTrue(try fixture.launches()[0].contains("--tools\n\n"))
    }

    func testCodexRegistersToolsRejectsUnknownCallsAndKeepsReadOnlyOnEveryTurn() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        emit '{"id":40,"method":"item/tool/call","params":{"callId":"edit-1","tool":"edit","arguments":{"value":"one"}}}'
        take
        emit '{"id":41,"method":"item/tool/call","params":{"callId":"bad","tool":"unknown","arguments":{}}}'
        take
        emit '{"id":42,"method":"item/fileChange/requestApproval","params":{}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let calls = ToolCalls(), recorder = AgentRuntimeRecorder(), completed = expectation(description: "finished")
        recorder.observe = { if case .status(.idle) = $0 { completed.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder, tools: .init([definition]) { call in
            await calls.append(call); return .init(text: "Edited")
        })
        defer { runtime.stop() }
        try await runtime.setAccess(.fullAccess)
        try await runtime.send(text: "edit", model: nil)
        await fulfillment(of: [completed], timeout: 5)
        let sent = try fixture.messages()
        let thread = try XCTUnwrap(sent.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertEqual(thread["sandbox"] as? String, "read-only")
        XCTAssertEqual((thread["dynamicTools"] as? [[String: Any]])?.first?["name"] as? String, "edit")
        let turn = try XCTUnwrap(sent.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(turn["approvalPolicy"] as? String, "never")
        XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, "readOnly")
        XCTAssertEqual((sent.first { $0["id"] as? Int == 40 }?["result"] as? [String: Any])?["success"] as? Bool, true)
        XCTAssertEqual((sent.first { $0["id"] as? Int == 41 }?["result"] as? [String: Any])?["success"] as? Bool, false)
        XCTAssertEqual((sent.first { $0["id"] as? Int == 42 }?["result"] as? [String: Any])?["decision"] as? String, "decline")
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try fixture.launches()[0].contains("features.shell_tool=false"))
    }

    func testStopCancelsApplicationHandlerAndDiscardsLateResults() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_request","request_id":"call","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"edit","arguments":{},"_meta":{"claudecode/toolUseId":"slow"}}}}}'
        hold
        """)
        defer { fixture.remove() }
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled"), closed = expectation(description: "closed")
        let recorder = AgentRuntimeRecorder()
        recorder.observe = { if case .status(.closed) = $0 { closed.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init([definition]) { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill() }
            return .init(text: "A late result must not overwrite interrupted state")
        })
        try await runtime.send(text: "slow", model: nil)
        await fulfillment(of: [started], timeout: 3)
        runtime.stop()
        await fulfillment(of: [cancelled, closed], timeout: 3)
        XCTAssertEqual(recorder.transcript["slow"]?.tool?.status, .interrupted)
        XCTAssertFalse(recorder.transcript["slow"]?.tool?.output?.contains("late result") == true)
    }
}

private actor ToolCalls {
    private var calls: [AgentToolCall] = []
    var count: Int { calls.count }
    func append(_ call: AgentToolCall) { calls.append(call) }
}
