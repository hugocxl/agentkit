import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

private actor ApplicationGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

final class AgentApplicationLifecycleTests: XCTestCase {
    private var definitions: [AgentToolDefinition] {
        ["slow", "edit", "read"].map { .init(name: $0, description: $0, inputSchema: ["type": "object"]) }
    }
    private let initialize = """
    take
    emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
    take
    emit '{"type":"control_request","request_id":"slow","request":{"subtype":"mcp_message","message":{"id":1,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"claudecode/toolUseId":"slow"}}}}}'
    while [ ! -f "$log.started" ]; do sleep 0.01; done
    """

    func testCompletedTurnRevokesRunningAndQueuedMutations() async throws {
        let fixture = try AgentRuntimeFixture(initialize + """

        emit '{"type":"control_request","request_id":"edit","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"edit","arguments":{},"_meta":{"claudecode/toolUseId":"edit"}}}}}'
        emit '{"type":"result","subtype":"success","result":"Done"}'
        hold
        """)
        defer { fixture.remove() }
        let gate = ApplicationGate(), recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "idle"), retired = expectation(description: "worker retired")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init(definitions) { call in
            if call.name == "slow" {
                let context = AgentToolExecutionContext.current
                try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".started"))
                await gate.wait()
                do {
                    try context?.withCommit { XCTFail("Late commit") }
                    XCTFail("Revoked context was accepted")
                } catch {}
                retired.fulfill()
            } else { XCTFail("Queued mutation ran after turn completion") }
            return .init(text: "Finished")
        })
        defer { runtime.stop() }
        try await runtime.send(text: "work", model: nil)
        await fulfillment(of: [idle], timeout: 3)
        await gate.release()
        await fulfillment(of: [retired], timeout: 3)
        XCTAssertEqual(recorder.transcript["edit"]?.tool?.status, .interrupted)
    }

    func testTimeoutRetiresUncooperativeWorkerAndDrainsQueue() async throws {
        let fixture = try AgentRuntimeFixture(initialize + """

        emit '{"type":"control_request","request_id":"read","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"read","arguments":{},"_meta":{"claudecode/toolUseId":"read"}}}}}'
        take
        take
        emit '{"type":"result","subtype":"success","result":"Done"}'
        hold
        """)
        defer { fixture.remove() }
        let gate = ApplicationGate(), recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "idle"), read = expectation(description: "read escaped blocked worker")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init(definitions, executionTimeout: 0.2) { call in
            if call.name == "slow" {
                try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".started"))
                await gate.wait()
            } else { read.fulfill() }
            return .init(text: "Done")
        })
        defer { runtime.stop() }
        try await runtime.send(text: "work", model: nil)
        await fulfillment(of: [read, idle], timeout: 3)
        XCTAssertEqual(recorder.transcript["slow"]?.tool?.status, .timedOut)
        await gate.release()
    }

    func testIndependentReadBypassesBlockedMutation() async throws {
        let fixture = try AgentRuntimeFixture(initialize + """

        emit '{"type":"control_request","request_id":"read","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"read","arguments":{},"_meta":{"claudecode/toolUseId":"read"}}}}}'
        take
        emit '{"type":"result","subtype":"success","result":"Done"}'
        hold
        """)
        defer { fixture.remove() }
        let gate = ApplicationGate(), recorder = AgentRuntimeRecorder()
        let read = expectation(description: "read"), idle = expectation(description: "idle")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init(definitions, concurrentTools: ["read"]) { call in
            if call.name == "slow" {
                try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".started"))
                await gate.wait()
            } else { read.fulfill() }
            return .init(text: "Done")
        })
        defer { runtime.stop() }
        try await runtime.send(text: "work", model: nil)
        await fulfillment(of: [read, idle], timeout: 3)
        await gate.release()
    }

    func testCodexImageProjectionRemovesDataURLs() throws {
        let bytes = Data([1, 2, 3])
        let result = AgentToolImages.project(["contentItems": [
            ["type": "inputImage", "imageUrl": "data:image/jpeg;base64," + bytes.base64EncodedString()],
        ]])
        XCTAssertEqual(result.images.map(\.data), [bytes])
        XCTAssertFalse(String(describing: result.output).contains("base64,"))
    }

    func testRecoveryRetiresQueuedToolsAsWellAsRunningTools() {
        var items: [AgentChatItem] = [AgentToolActivity.Status.queued, .running].map { status in
            AgentChatItem(kind: .tool, text: "Edit", isComplete: false,
                          tool: .init(name: "edit", category: .other, status: status))
        }
        AgentSessions.finishItems(&items)
        XCTAssertTrue(items.allSatisfy { $0.isComplete && $0.tool?.status == .interrupted })
    }

    func testInterruptAllowsNewTurnBeforeOldWorkerReturns() async throws {
        let fixture = try AgentRuntimeFixture(initialize + """

        take
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"2","response":{}}}'
        emit '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Interrupted"}'
        take
        emit '{"type":"control_request","request_id":"read","request":{"subtype":"mcp_message","message":{"id":2,"method":"tools/call","params":{"name":"read","arguments":{},"_meta":{"claudecode/toolUseId":"read"}}}}}'
        take
        emit '{"type":"result","subtype":"success","result":"Done"}'
        hold
        """)
        defer { fixture.remove() }
        let gate = ApplicationGate(), recorder = AgentRuntimeRecorder()
        let started = expectation(description: "blocked worker started")
        let stopped = expectation(description: "old turn interrupted")
        let read = expectation(description: "new turn read completed")
        recorder.observe = { if case .status(.idle) = $0, recorder.statuses.filter({ $0 == .idle }).count == 1 { stopped.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder, tools: .init(definitions) { call in
            if call.name == "slow" {
                try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".started"))
                started.fulfill()
                await gate.wait()
            } else { read.fulfill() }
            return .init(text: "Done")
        })
        defer { runtime.stop() }
        try await runtime.send(text: "old", model: nil)
        await fulfillment(of: [started], timeout: 3)
        try await runtime.interrupt()
        await fulfillment(of: [stopped], timeout: 3)
        try await runtime.send(text: "new", model: nil)
        await fulfillment(of: [read], timeout: 3)
        XCTAssertEqual(recorder.transcript["slow"]?.tool?.status, .interrupted)
        await gate.release()
    }

    func testCodexRejectsForeignToolCallsAndLateTurnCompletion() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"active"}}}'
        emit '{"id":40,"method":"item/tool/call","params":{"threadId":"other","turnId":"active","callId":"foreign","tool":"edit","arguments":{}}}'
        take
        emit '{"id":41,"method":"item/tool/call","params":{"threadId":"thread","turnId":"old","callId":"stale","tool":"edit","arguments":{}}}'
        take
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"old","status":"completed"}}}'
        emit '{"id":42,"method":"item/tool/call","params":{"threadId":"thread","turnId":"active","callId":"current","tool":"read","arguments":{}}}'
        take
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"active","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder(), done = expectation(description: "done")
        recorder.observe = { if case .status(.idle) = $0 { done.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder, tools: .init(definitions) { call in
            XCTAssertEqual(call.id, "current")
            return .init(text: "Read")
        })
        defer { runtime.stop() }
        try await runtime.send(text: "read", model: nil)
        await fulfillment(of: [done], timeout: 3)
        let messages = try fixture.messages()
        for id in [40, 41] {
            XCTAssertEqual((messages.first { $0["id"] as? Int == id }?["result"] as? [String: Any])?["success"] as? Bool, false)
        }
        XCTAssertEqual(recorder.transcript["current"]?.tool?.status, .completed)
    }

    func testOversizedSuccessfulResultPreservesCommitAndFullOutput() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        emit '{"id":40,"method":"item/tool/call","params":{"callId":"edit","tool":"edit","arguments":{}}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let original = AgentJSONValue.object(["mutation": "committed", "revision": "new", "data": .string(String(repeating: "x", count: 1_100_000))]).text
        let recorder = AgentRuntimeRecorder(), done = expectation(description: "done")
        recorder.observe = { if case .status(.idle) = $0 { done.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder, tools: .init(definitions) { _ in .init(text: original) })
        defer { runtime.stop() }
        try await runtime.send(text: "edit", model: nil)
        await fulfillment(of: [done], timeout: 3)
        let payload = try XCTUnwrap(try fixture.messages().first { $0["id"] as? Int == 40 }?["result"] as? [String: Any])
        XCTAssertEqual(payload["success"] as? Bool, true)
        let text = try XCTUnwrap((payload["contentItems"] as? [[String: Any]])?.first?["text"] as? String)
        let summary = try AgentJSONValue.decode(Data(text.utf8))
        XCTAssertEqual(summary["mutation"]?.string, "committed")
        XCTAssertEqual(recorder.transcript["edit"]?.tool?.output, original)
        XCTAssertEqual(recorder.transcript["edit"]?.tool?.status, .completed)
    }
}
