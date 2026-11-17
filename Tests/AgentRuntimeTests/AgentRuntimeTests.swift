import AgentCore
import Foundation
import XCTest
@testable import AgentRuntime

final class AgentRuntimeTests: XCTestCase {
    func testClaudePlanModeWaitsForNativeAcknowledgementBeforeUserInput() async throws {
        let recorder = AgentRuntimeRecorder()
        let received = expectation(description: "provider consumed the planned prompt")
        recorder.observe = { if case .status(.idle) = $0 { received.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"2","response":{}}}'
        take
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Plan"}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setPlan(true)
        try await runtime.send(text: "Plan this change", model: nil)
        await fulfillment(of: [received], timeout: 3)
        let messages = try fixture.messages()
        let request = try XCTUnwrap(messages[1]["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "set_permission_mode")
        XCTAssertEqual(request["mode"] as? String, "plan")
        XCTAssertEqual(messages.last?["type"] as? String, "user")
    }

    func testCodexPlanModeAndExplicitDefaultResetReachNativeTurns() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"one","status":"completed"}}}'
        take
        emit '{"id":4,"result":{"turn":{"id":"two"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setPlan(true)
        try await runtime.send(text: "Plan", model: "test-model", reasoningEffort: .high)
        // Flush the completed notification already written by the fixture.
        try await Task.sleep(for: .milliseconds(50))
        try await runtime.setPlan(false)
        try await runtime.send(text: "Build", model: "test-model", reasoningEffort: .high)
        let turns = try fixture.messages().filter { $0["method"] as? String == "turn/start" }
        XCTAssertEqual(turns.count, 2)
        for (index, turn) in turns.enumerated() {
            let params = try XCTUnwrap(turn["params"] as? [String: Any])
            let mode = try XCTUnwrap(params["collaborationMode"] as? [String: Any])
            XCTAssertEqual(mode["mode"] as? String, index == 0 ? "plan" : "default")
            let settings = try XCTUnwrap(mode["settings"] as? [String: Any])
            XCTAssertEqual(settings["model"] as? String, "test-model")
            XCTAssertTrue(settings["developer_instructions"] is NSNull)
        }
    }

    func testCodexResumedAutoEffortFindsSelectedModelOnLaterCatalogPage() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "later-page selection completed")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"resumed"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"model":"first","isDefault":true}],"nextCursor":"next"}}'
        take
        emit '{"id":5,"result":{"data":[{"model":"later-page","defaultReasoningEffort":"ultra"}]}}'
        take
        emit '{"id":6,"result":{"turn":{"id":"turn"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "resumed")
        defer { runtime.stop() }
        try await runtime.send(text: "Hello", model: "later-page")
        await fulfillment(of: [idle], timeout: 5)
        let sent = try fixture.messages()
        XCTAssertEqual((sent[5]["params"] as? [String: Any])?["cursor"] as? String, "next")
        XCTAssertEqual((sent[6]["params"] as? [String: Any])?["effort"] as? String, "ultra")
        XCTAssertEqual((sent[6]["params"] as? [String: Any])?["model"] as? String, "later-page")
    }

    func testClaudeFollowupQueuedPastTheResultGetsItsOwnTurn() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "both responses finish")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        // Claude 2.1 answers a follow-up sent without a tool boundary after the
        // current result, echoing it when that second turn starts.
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        take
        emit '{"type":"result","subtype":"success","result":"First"}'
        replay
        emit '{"type":"result","subtype":"success","result":"Second"}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: nil)
        try await runtime.steer(text: "Follow up", attachments: [])
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.statuses, [.working, .working, .idle])
        let launch = try XCTUnwrap(fixture.launches().first)
        XCTAssertTrue(launch.contains("--replay-user-messages"))
        let users = try fixture.messages().filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual((users[1]["message"] as? [String: Any])?["content"] as? String, "Follow up")
        XCTAssertNotNil(users[1]["uuid"] as? String)
    }

    /// Stopping Claude with a follow-up it hasn't taken replaces its process; until the old
    /// one has exited, the runtime says so, as it may still change files.
    func testAProcessClaudeStoppedCountsUntilItExits() async throws {
        let recorder = AgentRuntimeRecorder()
        // A provider that takes no notice of being asked to stop, so it exits only when killed.
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        exec sleep 30
        """)
        defer { fixture.remove() }
        // Stopped, it stays until the test is done.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.terminate() }
        try await runtime.send(text: "Start", model: nil)
        try await runtime.steer(text: "Follow up", attachments: [])
        let folder = revertScope(fixture.directory.path)
        XCTAssertFalse(runtime.isStopping(in: folder))
        try await runtime.interrupt()
        XCTAssertTrue(runtime.isStopping(in: folder), "The stopped process still exits")
    }

    /// A provider that fails stops its process, which counts as exiting until it has: it
    /// may still change files.
    func testAFailedProvidersProcessCountsUntilItExits() async throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        take
        emit 'not-json'
        exec sleep 30
        """)
        defer { fixture.remove() }
        // Stopped, it stays until the test is done.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.terminate() }
        do { try await runtime.send(text: "hello", model: nil); XCTFail("Expected startup failure") } catch {}
        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertTrue(runtime.isStopping(in: revertScope(fixture.directory.path)), "The failed provider's process still exits")
    }

    /// Once a stop is asked for, a follow-up is refused rather than joining the turn being
    /// stopped, in order with the stop on the runtime's queue.
    func testAFollowUpAfterAStopIsRefused() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        take
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: nil)
        try await runtime.interrupt()
        do {
            try await runtime.steer(text: "Too late", attachments: [])
            XCTFail("Refused once the stop is asked for")
        } catch {
            XCTAssertTrue(error is AgentFollowUpRefused, "\(error)")
        }
    }

    /// A follow-up's hand-over goes to whichever comes first, the provider taking it or Stop.
    func testAFollowUpIsHandedOverOrStoppedNeverBoth() {
        let taken = AgentDelivery()
        XCTAssertTrue(taken.handOver())
        XCTAssertFalse(taken.cancel(), "Too late to stop")
        XCTAssertTrue(taken.handOver())
        let stopped = AgentDelivery()
        XCTAssertTrue(stopped.cancel())
        XCTAssertFalse(stopped.handOver(), "Never handed over once stopped")
        XCTAssertTrue(stopped.cancel())
    }

    /// A follow-up whose hand-over was cancelled is refused without reaching the provider.
    func testAFollowUpWhoseHandOverWasCancelledIsRefused() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: nil)
        let delivery = AgentDelivery()
        delivery.cancel()
        do {
            try await runtime.steer(text: "Stopped", attachments: [], delivery: delivery)
            XCTFail("Refused")
        } catch {
            XCTAssertTrue(error is AgentFollowUpRefused, "\(error)")
        }
        XCTAssertFalse(runtime.isStopping(in: revertScope(fixture.directory.path)))
    }

    /// A provider process the transport ends itself, as for a line past the limit, counts as
    /// stopping until it has exited.
    func testAProcessEndedForAnOversizedLineCountsAsStopping() throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        head -c 4096 /dev/zero | tr '\\0' 'x'
        exec sleep 30
        """)
        defer { fixture.remove() }
        // Ended, it stays until the test is done.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let ended = DispatchSemaphore(value: 0)
        let process = try AgentProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                     environment: AgentProcess.environment()),
                                       directory: fixture.directory.path, maxLineBytes: 1024,
                                       onLine: { _ in }, onExit: { _, _ in ended.signal() })
        defer { process.stop(); process.waitForExit() }
        var stopping = false
        for _ in 0..<100 where !stopping {
            stopping = process.isStopping
            if !stopping { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(stopping, "Ended by the transport, it still runs until killed")
        _ = ended
    }

    /// A provider the transport ends itself, for a line or unended output past the limit, is
    /// killed when it takes no notice, as a stopped one is, rather than running on.
    func testAProcessEndedForOversizedOutputIsKilledWhenItTakesNoNotice() throws {
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 0.2
        defer { AgentProcess.stopGrace = grace }
        for output in ["printf '%s\\n' \"$(head -c 4096 /dev/zero | tr '\\0' 'x')\"", "head -c 4096 /dev/zero | tr '\\0' 'x'"] {
            let fixture = try AgentRuntimeFixture("""
            trap '' TERM
            \(output)
            exec sleep 30
            """)
            defer { fixture.remove() }
            let exited = DispatchSemaphore(value: 0)
            let process = try AgentProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                         environment: AgentProcess.environment()),
                                           directory: fixture.directory.path, maxLineBytes: 1024,
                                           onLine: { _ in }, onExit: { _, _ in exited.signal() })
            defer { process.stop(); process.waitForExit() }
            XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "Killed without being stopped: \(output)")
            XCTAssertFalse(process.isStopping)
        }
    }

    /// Asking whether a process stops never waits behind a write to a provider that stopped
    /// reading, which can hold its input for seconds.
    func testWhetherAProcessStopsIsKnownDuringAStalledWrite() throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        emit 'ready'
        exec sleep 30
        """)
        defer { fixture.remove() }
        let ready = DispatchSemaphore(value: 0)
        let process = try AgentProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                     environment: AgentProcess.environment()),
                                       directory: fixture.directory.path, onLine: { _ in ready.signal() }, onExit: { _, _ in })
        defer { process.stop(); process.waitForExit() }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success, "It ignores being asked to stop")
        // Larger than the pipe holds, to a provider that never reads it: the write holds the
        // input, and is kept there, waiting for the provider, until the test is done.
        let waiting = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), wrote = DispatchSemaphore(value: 0)
        process.onWriteWaiting = { waiting.signal(); release.wait(); release.signal() }
        DispatchQueue.global().async {
            try? process.write(["type": "user", "text": String(repeating: "x", count: 1_000_000)])
            wrote.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 10), .success)
        defer { release.signal(); _ = wrote.wait(timeout: .now() + 10) }
        // Stop itself waits for the input; whether it was asked for is known meanwhile.
        DispatchQueue.global().async { process.stop() }
        let known = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(20)
            var stopping = false
            while !stopping, Date() < deadline {
                stopping = process.isStopping
                if !stopping { Thread.sleep(forTimeInterval: 0.01) }
            }
            if stopping { known.signal() }
        }
        XCTAssertEqual(known.wait(timeout: .now() + 10), .success, "Known while the write still holds the input")
    }

    /// A runtime told to launch nothing more starts no provider, however late its start runs.
    func testARefusedRuntimeLaunchesNoProvider() async throws {
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        runtime.refuseLaunches()
        do { try await runtime.send(text: "hello", model: nil); XCTFail("Nothing launched") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path + ".args"), "No provider started")
        XCTAssertFalse(runtime.mayRun(in: revertScope(fixture.directory.path)))
    }

    /// Each provider process keeps the folder it launched in: one that replaced a stopped
    /// process after the folder's link was pointed elsewhere runs in the new folder, while
    /// the stopped one still counts in the old.
    func testAReplacementProviderKeepsItsOwnFolder() async throws {
        // Each launch answers its own initialize request.
        let fixture = try AgentRuntimeFixture(#"""
        trap '' TERM
        take
        id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        exec sleep 30
        """#)
        defer { fixture.remove() }
        let first = fixture.directory.appendingPathComponent("first"), second = fixture.directory.appendingPathComponent("second")
        let link = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: first.path)
        // The stopped provider stays until its overlap with the next is checked.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let recorder = AgentRuntimeRecorder()
        let runtime = AgentRuntime(provider: .claude, directory: link.path, resumeSession: nil,
                                   launchBuilder: { arguments in
                                       .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path] + arguments,
                                             environment: AgentProcess.environment())
                                   }, requestTimeout: 3, onEvent: { recorder.receive($0) })
        defer { runtime.terminate() }
        try await runtime.send(text: "Start", model: nil)
        try await runtime.steer(text: "Follow up", attachments: [])
        // Stopped with its follow-up untaken, its process is replaced at the next message.
        try await runtime.interrupt()
        let firstFolder = revertScope(first.path), secondFolder = revertScope(second.path)
        XCTAssertTrue(runtime.isStopping(in: firstFolder))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: second.path)
        try await runtime.send(text: "Again", model: nil)
        XCTAssertTrue(runtime.mayRun(in: secondFolder), "The new provider runs in the folder the link leads to now")
        XCTAssertTrue(runtime.isStopping(in: firstFolder), "The stopped one still counts where it ran")
        XCTAssertFalse(runtime.isStopping(in: secondFolder))
    }

    /// Codex works in the physical folder its provider launched in, even when a link on the
    /// way is pointed elsewhere while it starts.
    func testCodexWorksInTheFolderItLaunchedIn() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        while [ ! -f "$log.gate" ]; do sleep 0.05; done
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        hold
        """)
        defer { fixture.remove() }
        let first = fixture.directory.appendingPathComponent("first"), second = fixture.directory.appendingPathComponent("second")
        let link = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: first.path)
        let recorder = AgentRuntimeRecorder()
        let runtime = AgentRuntime(provider: .codex, directory: link.path, resumeSession: nil,
                                   launchBuilder: { arguments in
                                       .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path] + arguments,
                                             environment: AgentProcess.environment())
                                   }, requestTimeout: 5, onEvent: { recorder.receive($0) })
        defer { runtime.stop() }
        let sending = Task { try await runtime.send(text: "Start", model: nil) }
        // Launched, and waiting for its first answer: the link is pointed elsewhere now.
        for _ in 0..<200 where ((try? fixture.messages()) ?? []).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: second.path)
        try Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate"))
        try await sending.value
        let start = try XCTUnwrap(fixture.messages().first { $0["method"] as? String == "thread/start" })
        let cwd = try XCTUnwrap((start["params"] as? [String: Any])?["cwd"] as? String)
        XCTAssertEqual(cwd, first.resolvingSymlinksInPath().path, "Codex works where its provider launched")
        XCTAssertTrue(runtime.mayRun(in: revertScope(first.path)))
        XCTAssertFalse(runtime.mayRun(in: revertScope(second.path)))
    }

    /// Providers started for discovery count in their folder from before they launch until
    /// they exit, stopping included, so a revert there waits for them.
    func testDiscoveryProvidersCountInTheirFolderUntilTheyExit() throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        emit 'ready'
        while [ ! -f "$log.gate" ]; do sleep 0.05; done
        """)
        defer { fixture.remove() }
        // Stopped, it stays until let go.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let tracker = AgentProcessTracker(), ready = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        let folder = revertScope(fixture.directory.path)
        let process = try tracker.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                               environment: AgentProcess.environment()),
                                         directory: fixture.directory.path, onLine: { _ in ready.signal() }, onExit: { _, _ in exited.signal() })
        defer { try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate")); process.stop(); process.waitForExit() }
        XCTAssertTrue(tracker.mayRun(in: folder))
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success, "It ignores being asked to stop")
        process.stop()
        XCTAssertTrue(tracker.mayRun(in: folder), "Stopping, it still counts")
        try Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate"))
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success)
        XCTAssertFalse(tracker.mayRun(in: folder), "Gone once it exited")
    }

    /// A discovery provider counts in its folder from before its process starts.
    func testADiscoveryProviderCountsBeforeItsProcessStarts() throws {
        let fixture = try AgentRuntimeFixture("exit 0")
        defer { fixture.remove() }
        let tracker = AgentProcessTracker(), reserved = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let launched = DispatchSemaphore(value: 0)
        tracker.onReserved = { reserved.signal(); release.wait() }
        DispatchQueue.global().async {
            let process = try? tracker.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                    environment: AgentProcess.environment()),
                                              directory: fixture.directory.path, onLine: { _ in }, onExit: { _, _ in })
            process?.stop()
            process?.waitForExit()
            launched.signal()
        }
        XCTAssertEqual(reserved.wait(timeout: .now() + 10), .success)
        defer { release.signal(); _ = launched.wait(timeout: .now() + 10) }
        XCTAssertTrue(tracker.mayRun(in: revertScope(fixture.directory.path)), "Reserved before it starts")
        XCTAssertEqual(tracker.processIDs(), [], "No process yet")
    }

    /// Reading a discovery provider's folder, which may stall on a slow volume, holds up no
    /// revert asking meanwhile whether a provider may run in its own.
    func testReadingADiscoveryProvidersFolderHoldsUpNoRevert() throws {
        let fixture = try AgentRuntimeFixture("exec sleep 30")
        defer { fixture.remove() }
        let tracker = AgentProcessTracker(), reading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        tracker.readFolder = { path in reading.signal(); release.wait(); return AgentFolder(path) }
        let launched = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let process = try? tracker.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                                    environment: AgentProcess.environment()),
                                              directory: fixture.directory.path, onLine: { _ in }, onExit: { _, _ in })
            process?.stop()
            process?.waitForExit()
            launched.signal()
        }
        XCTAssertEqual(reading.wait(timeout: .now() + 10), .success)
        defer { release.signal(); _ = launched.wait(timeout: .now() + 10) }
        let elsewhere = revertScope(FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID())").path)
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = tracker.mayRun(in: elsewhere); answered.signal() }
        XCTAssertEqual(answered.wait(timeout: .now() + 10), .success, "Answered while the folder is still being read")
    }

    /// A folder meets itself however its path is spelled, and the folders inside and around
    /// it, but neither one beside it nor one a link on its path passes through.
    func testFoldersMeetTheFoldersInsideAndAroundThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer"), inner = outer.appendingPathComponent("inner")
        let beside = root.appendingPathComponent("beside"), link = beside.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: inner.path)
        let folder = AgentFolder(outer.path)
        XCTAssertTrue(folder.overlaps(AgentFolder(outer.path + "/../outer")), "Itself, however spelled")
        XCTAssertTrue(folder.overlaps(AgentFolder(inner.path)), "A folder inside it")
        XCTAssertTrue(AgentFolder(inner.path).overlaps(folder), "A folder around it")
        XCTAssertTrue(AgentFolder(link.path).overlaps(AgentFolder(inner.path)), "Itself, through a link")
        XCTAssertTrue(AgentFolder(link.path).overlaps(folder), "Around the folder a link leads to")
        XCTAssertFalse(AgentFolder(link.path).overlaps(AgentFolder(beside.path)), "Not the folder a link passes through")
        XCTAssertFalse(folder.overlaps(AgentFolder(beside.path)), "Not a folder beside it")
    }

    /// A provider counts in the folders around its own and inside it, where its work may
    /// change files a revert there restores, but not in a folder beside it.
    func testAProviderCountsInTheFoldersAroundAndInsideItsOwn() async throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        while [ ! -f "$log.gate" ]; do sleep 0.05; done
        """)
        defer { fixture.remove() }
        // Stopped, it stays until let go.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let project = fixture.directory.appendingPathComponent("project"), inner = project.appendingPathComponent("inner")
        let beside = fixture.directory.appendingPathComponent("beside")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        let recorder = AgentRuntimeRecorder()
        let runtime = AgentRuntime(provider: .claude, directory: project.path, resumeSession: nil,
                                   launchBuilder: { arguments in
                                       .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path] + arguments,
                                             environment: AgentProcess.environment())
                                   }, requestTimeout: 5, onEvent: { recorder.receive($0) })
        defer { try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate")); runtime.terminate() }
        try await runtime.send(text: "Start", model: nil)
        XCTAssertTrue(runtime.mayRun(in: revertScope(fixture.directory.path)), "Around its folder")
        XCTAssertTrue(runtime.mayRun(in: revertScope(inner.path)), "Inside its folder")
        XCTAssertFalse(runtime.mayRun(in: revertScope(beside.path)), "Not beside it")
        runtime.stop()
        XCTAssertTrue(runtime.isStopping(in: revertScope(fixture.directory.path)), "Stopping, around its folder")
        XCTAssertTrue(runtime.isStopping(in: revertScope(inner.path)), "Stopping, inside its folder")
        XCTAssertFalse(runtime.isStopping(in: revertScope(beside.path)))
    }

    /// A folder meets the folders around it under every name the system gives them: through
    /// `/private`, which Foundation's resolved paths leave out, and on the data volume a
    /// firmlink leads into.
    func testFoldersMeetTheFoldersAroundThemUnderEveryName() {
        XCTAssertTrue(AgentFolder("/tmp").overlaps(AgentFolder("/private")), "Around it, through /private")
        XCTAssertTrue(AgentFolder("/tmp").overlaps(AgentFolder("/System/Volumes/Data")), "Around it, on the data volume")
        XCTAssertTrue(AgentFolder("/Users/Shared").overlaps(AgentFolder("/System/Volumes/Data/Users")), "Around it, behind the firmlink")
        XCTAssertFalse(AgentFolder("/tmp").overlaps(AgentFolder("/Users")), "Not a folder beside it")
    }

    /// A provider whose folder moved into another since it launched is found there by where
    /// it works now, which the folders around it at its launch no longer tell.
    func testAProviderIsFoundWhereItWorksNowAfterItsFolderMoved() async throws {
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        while [ ! -f "$log.gate" ]; do sleep 0.05; done
        """)
        defer { fixture.remove() }
        // Stopped, it stays until let go.
        let grace = AgentProcess.stopGrace
        AgentProcess.stopGrace = 30
        defer { AgentProcess.stopGrace = grace }
        let outside = fixture.directory.appendingPathComponent("outside"), project = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let recorder = AgentRuntimeRecorder()
        let runtime = AgentRuntime(provider: .claude, directory: outside.path, resumeSession: nil,
                                   launchBuilder: { arguments in
                                       .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path] + arguments,
                                             environment: AgentProcess.environment())
                                   }, requestTimeout: 5, onEvent: { recorder.receive($0) })
        defer { try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate")); runtime.terminate() }
        try await runtime.send(text: "Start", model: nil)
        XCTAssertEqual(runtime.providerProcesses().count, 1)
        XCTAssertFalse(runtime.mayRun(in: revertScope(project.path, candidates: runtime.providerProcesses())), "Beside the project")
        // Its folder moves into the project while it works.
        try FileManager.default.moveItem(at: outside, to: project.appendingPathComponent("moved"))
        runtime.stop()
        XCTAssertFalse(runtime.isStopping(in: revertScope(project.path)), "Where it launched no longer tells")
        XCTAssertTrue(runtime.isStopping(in: revertScope(project.path, candidates: runtime.providerProcesses())), "Where it works now does")
        XCTAssertTrue(runtime.mayRun(in: revertScope(project.path, candidates: runtime.providerProcesses())))
    }

    /// Where a process works is trusted only once the system's name for it leads there: a deep
    /// folder's name is cut short, and a removed one's may lead to whatever took its place, so
    /// either process may be working anywhere and holds every revert.
    func testWhereAProcessWorksIsTrustedOnlyWhenItsNameLeadsThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cwd-\(UUID())")
        let replaced = root.appendingPathComponent("replaced"), elsewhere = root.deletingLastPathComponent().appendingPathComponent("agent-elsewhere-\(UUID())")
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: elsewhere)
            // Too deep for paths: removed a folder at a time.
            let remove = Process()
            remove.executableURL = URL(fileURLWithPath: "/bin/rm")
            remove.arguments = ["-rf", root.path]
            try? remove.run()
            remove.waitUntilExit()
        }
        var workers: [Process] = []
        defer { for worker in workers { worker.terminate(); worker.waitUntilExit() } }
        func launch(_ script: String, in folder: URL) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.currentDirectoryURL = folder
            try process.run()
            workers.append(process)
            return process
        }
        let here = try launch("exec sleep 30", in: root)
        // Deeper than a path the system names whole.
        let deep = try launch("for i in $(seq 1 60); do mkdir d0123456789012345678901234567890 && cd d0123456789012345678901234567890 || exit 1; done; touch '\(root.path)/deep'; exec sleep 30", in: root)
        let moved = try launch("exec sleep 30", in: replaced)
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: root.path + "/deep") { Thread.sleep(forTimeInterval: 0.01) }
        // Removed, and another folder made in its place.
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        guard case .folder(let path)? = AgentProcess.workingDirectory(of: here.processIdentifier) else { return XCTFail("Told where it works") }
        XCTAssertEqual(AgentFolder(path).identity, AgentFolder(root.path).identity)
        XCTAssertEqual(AgentProcess.workingDirectory(of: deep.processIdentifier), .unknown, "Its name is cut short")
        XCTAssertEqual(AgentProcess.workingDirectory(of: moved.processIdentifier), .unknown, "Its name leads to another folder")
        XCTAssertEqual(revertScope(elsewhere.path, candidates: [here, deep, moved].map(\.processIdentifier)).processes,
                       [deep.processIdentifier, moved.processIdentifier], "Either may work there")
        here.terminate()
        here.waitUntilExit()
        XCTAssertNil(AgentProcess.workingDirectory(of: here.processIdentifier), "Gone")
    }

    /// Another user's process, which this one can't read, may work anywhere.
    func testAProcessThatCantBeReadMayWorkAnywhere() throws {
        try XCTSkipIf(geteuid() == 0, "Root reads every process")
        XCTAssertEqual(AgentProcess.workingDirectory(of: 1), .unknown)
    }

    /// A discovery provider counts until it has exited, even while a helper it started still
    /// holds its output open.
    func testADiscoveryProviderStopsCountingOnceItExitsThoughItsOutputStaysOpen() throws {
        // The helper stops when let go, or after a minute at most.
        let fixture = try AgentRuntimeFixture("""
        (i=0; while [ ! -f "$log.gate" ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i+1)); done) &
        echo $! > "$log.helper"
        emit 'ready'
        exit 0
        """)
        defer { fixture.remove() }
        let tracker = AgentProcessTracker(), ready = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        let process = try tracker.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                               environment: AgentProcess.environment()),
                                         directory: fixture.directory.path, onLine: { _ in ready.signal() }, onExit: { _, _ in exited.signal() })
        defer {
            try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate"))
            if let helper = pid_t((try? String(contentsOfFile: fixture.log.path + ".helper", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                kill(helper, SIGKILL)
            }
            XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "Its output closes once the helper is gone")
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        for _ in 0..<1000 where process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(process.isRunning, "The provider exited")
        XCTAssertFalse(tracker.mayRun(in: revertScope(fixture.directory.path)), "A helper holding its output keeps no revert waiting")
        XCTAssertEqual(tracker.processIDs(), [])
    }

    /// A discovery provider whose folder moved since it launched is found where it works now.
    func testADiscoveryProviderIsFoundWhereItWorksNowAfterItsFolderMoved() throws {
        let fixture = try AgentRuntimeFixture("""
        emit 'ready'
        while [ ! -f "$log.gate" ]; do sleep 0.05; done
        """)
        defer { fixture.remove() }
        let outside = fixture.directory.appendingPathComponent("outside"), project = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let tracker = AgentProcessTracker(), ready = DispatchSemaphore(value: 0)
        let process = try tracker.launch(.init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
                                               environment: AgentProcess.environment()),
                                         directory: outside.path, onLine: { _ in ready.signal() }, onExit: { _, _ in })
        defer { try? Data().write(to: URL(fileURLWithPath: fixture.log.path + ".gate")); process.stop(); process.waitForExit() }
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(tracker.processIDs(), [process.processIdentifier])
        try FileManager.default.moveItem(at: outside, to: project.appendingPathComponent("moved"))
        XCTAssertFalse(tracker.mayRun(in: revertScope(project.path)), "Where it launched no longer tells")
        XCTAssertTrue(tracker.mayRun(in: revertScope(project.path, candidates: tracker.processIDs())), "Where it works now does")
    }

    /// After a background agent finishes, Claude answers it in a turn nobody sent. That
    /// turn is reported, and a prompt sent meanwhile waits for it instead of being
    /// refused or ended by its result.
    func testClaudeTurnItBeginsItselfIsATurnAndHoldsASendUntilItEnds() async throws {
        let recorder = AgentRuntimeRecorder()
        let started = expectation(description: "Claude starts its own turn")
        let done = expectation(description: "the held prompt's turn finishes")
        recorder.observe = { event in
            if case .providerTurn = event { started.fulfill() }
            if case .status(.idle) = event, recorder.statuses.count == 5 { done.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"result","subtype":"success","result":"LAUNCHED"}'
        emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_own"}},"parent_tool_use_id":null}'
        emit '{"type":"assistant","message":{"id":"msg_own","content":[{"type":"text","text":"The agent finished."}]},"parent_tool_use_id":null}'
        sleep 0.4
        emit '{"type":"result","subtype":"success","result":"The agent finished."}'
        take
        emit '{"type":"result","subtype":"success","result":"Second"}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: nil)
        await fulfillment(of: [started], timeout: 5)
        try await runtime.send(text: "Next", model: nil)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(recorder.statuses, [.working, .idle, .working, .working, .idle])
        XCTAssertEqual(recorder.transcript["msg_own"]?.text, "The agent finished.")
        let users = try fixture.messages().filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users.count, 2, "The held prompt is written once, after Claude's own turn")
    }

    func testClaudeFollowupFoldedIntoTheRunningTurnFinishesWithItsSingleResult() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "the folded turn finishes")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        // A follow-up sent during a tool call joins the current turn at the tool
        // boundary: Claude echoes it there and emits a single result.
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        take
        replay
        emit '{"type":"result","subtype":"success","result":"Both"}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: nil)
        try await runtime.steer(text: "Follow up", attachments: [])
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.statuses, [.working, .idle])
        do {
            try await runtime.steer(text: "Too late", attachments: [])
            XCTFail("A finished turn must not accept a follow-up")
        } catch {
            XCTAssertTrue(error is AgentTurnFinishedError)
        }
    }

    func testCodexCompactUsesNativeAPIInsteadOfSendingSlashText() async throws {
        let recorder = AgentRuntimeRecorder()
        let finished = expectation(description: "Compaction completed")
        recorder.observe = { if case .status(.idle) = $0 { finished.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{}}'
        emit '{"method":"turn/started","params":{"threadId":"thread","turn":{"id":"compact-turn","status":"inProgress"}}}'
        emit '{"method":"item/started","params":{"threadId":"thread","turnId":"compact-turn","item":{"id":"compact-item","type":"contextCompaction"}}}'
        emit '{"method":"item/completed","params":{"threadId":"thread","turnId":"compact-turn","item":{"id":"compact-item","type":"contextCompaction"}}}'
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"compact-turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "thread")
        defer { runtime.stop() }
        try await runtime.send(text: "/compact", model: nil)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(recorder.transcript["compact-item"]?.workContext?.sourceStatus, "completed")
        let messages = try fixture.messages()
        XCTAssertEqual(messages.last?["method"] as? String, "thread/compact/start")
        XCTAssertFalse(messages.contains { $0["method"] as? String == "turn/start" })
    }

    func testCodexReviewArgumentsChooseNativeTargets() async throws {
        for (command, kind, key, value) in [("/review branch main", "baseBranch", "branch", "main"), ("/review commit abc123", "commit", "sha", "abc123")] {
            let fixture = try AgentRuntimeFixture("""
            take
            emit '{"id":1,"result":{}}'
            take
            take
            emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
            take
            emit '{"id":3,"result":{}}'
            hold
            """)
            defer { fixture.remove() }
            let runtime = fixture.runtime(.codex, recorder: AgentRuntimeRecorder())
            defer { runtime.stop() }
            try await runtime.send(text: command, model: nil)
            let sent = try XCTUnwrap(fixture.messages().last)
            XCTAssertEqual(sent["method"] as? String, "review/start")
            let target = (sent["params"] as? [String: Any])?["target"] as? [String: String]
            XCTAssertEqual(target?["type"], kind); XCTAssertEqual(target?[key], value)
        }
    }

    func testCodexSteersActiveTurnWithoutStartingAnotherTurn() async throws {
        let recorder = AgentRuntimeRecorder()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"active"}}}'
        take
        emit '{"id":4,"result":{"turnId":"active"}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: "test-model")
        try await runtime.steer(text: "Focus on tests", attachments: [])
        let messages = try fixture.messages()
        let steer = try XCTUnwrap(messages.last)
        XCTAssertEqual(steer["method"] as? String, "turn/steer")
        let params = try XCTUnwrap(steer["params"] as? [String: Any])
        XCTAssertEqual(params["expectedTurnId"] as? String, "active")
        XCTAssertNil(params["model"])
        XCTAssertEqual(messages.filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    /// A Codex agent's own thread finishing must not end the conversation's turn or put
    /// the agent's messages in it.
    func testCodexChildThreadNotificationsStayOutOfTheParentTurn() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "the parent turn ends")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"active"}}}'
        emit '{"method":"item/agentMessage/delta","params":{"threadId":"child-thread","turnId":"child-turn","itemId":"child-msg","delta":"child text"}}'
        emit '{"method":"turn/completed","params":{"threadId":"child-thread","turn":{"id":"child-turn","status":"completed"}}}'
        emit '{"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"active","itemId":"parent-msg","delta":"parent text"}}'
        sleep 0.2
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"active","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: "test-model")
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.statuses, [.working, .idle], "Only the parent's own completion ends its turn")
        XCTAssertNil(recorder.transcript["child-msg"])
        XCTAssertEqual(recorder.transcript["parent-msg"]?.text, "parent text")
    }

    /// Rate limits and retries used to be invisible: the pane showed plain work for minutes.
    func testRateLimitEventsAndCodexRetriesBecomeActivity() async throws {
        // Shape from a recorded Claude Code 2.1.311 stream.
        let warning = AgentRuntime.rateLimitActivity(["status": "allowed_warning", "resetsAt": 1794585600,
                                                      "rateLimitType": "five_hour", "utilization": 0.98])
        XCTAssertEqual(warning?.kind, .rateLimitWarning)
        XCTAssertEqual(warning?.message, "98% of the usage limit used")
        XCTAssertEqual(warning?.resumesAt, Date(timeIntervalSince1970: 1794585600))
        XCTAssertEqual(AgentRuntime.rateLimitActivity(["status": "rejected", "resetsAt": 1794585600])?.kind, .rateLimited)
        XCTAssertNil(AgentRuntime.rateLimitActivity(["status": "allowed"]))

        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "the turn ends")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"active"}}}'
        emit '{"method":"error","params":{"threadId":"thread","turnId":"active","willRetry":true,"error":{"message":"Model overloaded"}}}'
        emit '{"method":"error","params":{"threadId":"thread","turnId":"active","willRetry":true,"error":{"message":"Model overloaded"}}}'
        emit '{"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"active","itemId":"m","delta":"ok"}}'
        emit '{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"active","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Start", model: "test-model")
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.activities.map { $0?.attempt }, [1, 2, nil], "Each retry counts, and output clears it")
        XCTAssertEqual(recorder.activities.first??.message, "Model overloaded")
        XCTAssertTrue(recorder.failures.isEmpty, "A retried error is not a failure")
    }

    /// A Claude command that answers with a result alone, such as `/cost`, showed nothing.
    func testClaudeResultWithoutMessagesShowsItsText() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "the command finishes")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Total cost: $0.01","uuid":"result-1"}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "/cost", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.transcript.values.filter { $0.kind == .assistant }.map(\.text), ["Total cost: $0.01"])
    }

    func testDynamicFutureReasoningPassesThroughBothProviderRuntimes() async throws {
        for provider in AgentChatProvider.allCases {
            let recorder = AgentRuntimeRecorder()
            let body = provider == .claude ? """
            take
            emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
            take
            emit '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
            hold
            """ : """
            take
            emit '{"id":1,"result":{}}'
            take
            take
            emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
            take
            emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
            emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
            hold
            """
            let fixture = try AgentRuntimeFixture(body)
            defer { fixture.remove() }
            let idle = expectation(description: "\(provider) future effort")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            let runtime = fixture.runtime(provider, recorder: recorder)
            defer { runtime.stop() }
            try await runtime.send(text: "Hello", model: "future-model", reasoningEffort: .init(rawValue: "future-effort"))
            await fulfillment(of: [idle], timeout: 5)
            if provider == .claude {
                XCTAssertTrue(try fixture.launches()[0].contains("--effort\nfuture-effort\n"))
            } else {
                let sent = try fixture.messages()
                XCTAssertEqual((sent.last?["params"] as? [String: Any])?["effort"] as? String, "future-effort")
            }
        }
    }

    // Protocol replays are synthetic, derived from the provider reference paths cited in the
    // provider implementations; no authentication, CLI install or billable request is used.
    func testClaudeStreamingApprovalToolResultAndNoDuplicateAnswer() async throws {
        let recorder = AgentRuntimeRecorder()
        let approval = expectation(description: "approval")
        let idle = expectation(description: "idle")
        recorder.observe = { event in
            if case .item(let item) = event, item.id == "permission-1", !item.isComplete { approval.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"system","subtype":"init","session_id":"claude-session","model":"test-model"}'
        emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"message-1","model":"test-model","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}}'
        emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}'
        printf '%s' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'
        printf '\\303'
        printf '\\251'
        printf '%s\\n' '"}}}'
        emit '{"type":"assistant","message":{"id":"message-1","content":[{"type":"text","text":"Hello é"},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}'
        emit '{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"pwd"}}}'
        take
        emit '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"/project"}]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Hello é","modelUsage":{"test-model":{"inputTokens":9000,"contextWindow":200000}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "prior-session")
        defer { runtime.stop() }
        // Lazy: constructing a runtime must not start even a fake executable.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        try await runtime.send(text: "Hi", model: "test-model")
        await fulfillment(of: [approval], timeout: 5)
        try await runtime.approve(request: "permission-1", allow: true)
        await fulfillment(of: [idle], timeout: 5)
        let state = recorder.transcript
        XCTAssertEqual(state["message-1"]?.text, "Hello é")
        XCTAssertEqual(state.values.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(state["tool-1"]?.detail, "/project")
        XCTAssertEqual(state["tool-1"]?.isComplete, true)
        XCTAssertEqual(state["permission-1"]?.text, "Approved")
        let sent = try fixture.messages()
        XCTAssertEqual((sent[0]["request"] as? [String: Any])?["subtype"] as? String, "initialize")
        XCTAssertEqual((sent[1]["message"] as? [String: Any])?["content"] as? String, "Hi")
        let response = sent[2]["response"] as? [String: Any]
        XCTAssertEqual(response?["request_id"] as? String, "permission-1")
        let decision = response?["response"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertEqual(decision?["toolUseID"] as? String, "tool-1")
        XCTAssertEqual((decision?["updatedInput"] as? [String: Any])?["command"] as? String, "pwd")
        XCTAssertTrue(recorder.sessions.contains("claude-session"))
        XCTAssertEqual(recorder.contextUsage.last, .init(usedTokens: 130, contextWindow: 200_000))
        XCTAssertEqual(recorder.resolvedModels, ["test-model"])
    }

    func testCodexResumeNumericZeroApprovalAndEarlyNotifications() async throws {
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "waiting")
        let idle = expectation(description: "idle")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"id":"test-model","model":"test-model","isDefault":true,"defaultReasoningEffort":"medium"}]}}'
        take
        emit '{"method":"turn/started","params":{"turn":{"id":"turn-1"}}}'
        emit '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","tokenUsage":{"last":{"totalTokens":1234},"total":{"totalTokens":999999},"modelContextWindow":258400}}}'
        emit '{"method":"thread/tokenUsage/updated","params":{"threadId":"child-thread","tokenUsage":{"last":{"totalTokens":9999},"modelContextWindow":1000000}}}'
        emit '{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"Done"}}'
        emit '{"id":0,"method":"item/commandExecution/requestApproval","params":{"itemId":"command-1","command":"pwd","availableDecisions":["accept","decline"]}}'
        emit '{"id":5,"result":{"turn":{"id":"turn-1"}}}'
        take
        emit '{"method":"item/completed","params":{"item":{"id":"command-1","type":"commandExecution","command":"pwd","aggregatedOutput":"/project","exitCode":0}}}'
        emit '{"method":"item/completed","params":{"item":{"id":"answer","type":"agentMessage","text":"Done"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "old-thread")
        defer { runtime.stop() }
        try await runtime.send(text: "Hello", model: "test-model")
        await fulfillment(of: [waiting], timeout: 5)
        try await runtime.approve(request: "0", allow: false)
        await fulfillment(of: [idle], timeout: 5)
        let sent = try fixture.messages()
        XCTAssertEqual(sent[0]["method"] as? String, "initialize")
        let clientInfo = (sent[0]["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["version"] as? String, AgentKitVersion.current)
        XCTAssertEqual(sent[1]["method"] as? String, "initialized")
        XCTAssertEqual(sent[2]["method"] as? String, "thread/resume")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["threadId"] as? String, "old-thread")
        XCTAssertEqual(sent[3]["method"] as? String, "config/read")
        XCTAssertEqual(sent[4]["method"] as? String, "model/list")
        XCTAssertEqual(sent[5]["method"] as? String, "turn/start")
        XCTAssertEqual((sent[5]["params"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(sent[6]["id"] as? Int, 0)
        XCTAssertEqual((sent[6]["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertEqual(recorder.transcript["answer"]?.text, "Done")
        XCTAssertEqual(recorder.transcript["command-1"]?.isComplete, true)
        XCTAssertEqual(recorder.transcript["0"]?.text, "Declined")
        XCTAssertEqual(recorder.sessions, ["thread-1"])
        XCTAssertEqual(recorder.contextUsage, [.init(usedTokens: 1234, contextWindow: 258_400)],
                       "Subagent thread notifications must not overwrite root context usage")
    }

    func testCodexInterruptWaitsForCompletionAndUsesTurnID() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "interrupted")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        take
        emit '{"id":4,"result":{}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"interrupted"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        XCTAssertFalse(recorder.statuses.contains(.idle))
        do {
            try await runtime.send(text: "concurrent", model: nil)
            XCTFail("Busy turn must not be submitted twice")
        } catch { XCTAssertTrue(error.localizedDescription.contains("current turn")) }
        try await runtime.interrupt()
        await fulfillment(of: [idle], timeout: 5)
        let message = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual(message["method"] as? String, "turn/interrupt")
        let params = message["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread")
        XCTAssertEqual(params?["turnId"] as? String, "turn")
    }

    func testClaudeInterruptCancelsApprovalAndEndsItsErrorResultAsAStop() async throws {
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "waiting")
        let stopped = expectation(description: "interrupted result")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.idle) = event { stopped.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1"}}'
        take
        emit '{"type":"control_request","request_id":"cancel-me","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}'
        take
        emit '{"type":"control_cancel_request","request_id":"cancel-me"}'
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"2"}}'
        emit '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["[ede_diagnostic] result_type=user"]}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        await fulfillment(of: [waiting], timeout: 5)
        try await runtime.interrupt()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(recorder.transcript["cancel-me"]?.text, "Cancelled")
        XCTAssertEqual(recorder.failures, [], "Claude ends an interrupted turn with an error result; that is the stop, not a failure")
        XCTAssertFalse(recorder.statuses.contains(.failed))
        let message = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual((message["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
    }

    func testClaudeErrorResultWithoutAStopFailsTheTurn() async throws {
        let recorder = AgentRuntimeRecorder()
        let failed = expectation(description: "error result")
        recorder.observe = { event in
            if case .status(.failed) = event { failed.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1"}}'
        take
        emit '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["fixture failure"]}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(recorder.failures, ["fixture failure"])
    }

    func testStartupTimeoutAndStopCancelPendingSend() async throws {
        for provider in AgentChatProvider.allCases {
            let recorder = AgentRuntimeRecorder()
            let fixture = try AgentRuntimeFixture("take\nhold")
            defer { fixture.remove() }
            let runtime = fixture.runtime(provider, recorder: recorder, timeout: 0.15)
            do {
                try await runtime.send(text: "never sent", model: nil)
                XCTFail("Handshake must time out")
            } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
            XCTAssertEqual(recorder.statuses.last, .failed)
            runtime.stop()
        }
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let working = expectation(description: "startup reserved")
        recorder.observe = { event in if case .status(.working) = event { working.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        let send = Task { try await runtime.send(text: "never sent", model: nil) }
        await fulfillment(of: [working], timeout: 5)
        runtime.stop()
        do { try await send.value; XCTFail("Stop must cancel handshake") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped")) }
    }

    func testExitReportsDrainedStderrAndMalformedJSONFails() async throws {
        for script in ["take\nprintf 'Sign in with codex login' >&2\nexit 7", "take\nemit 'not-json'\nhold"] {
            let fixture = try AgentRuntimeFixture(script)
            defer { fixture.remove() }
            let recorder = AgentRuntimeRecorder()
            let runtime = fixture.runtime(.codex, recorder: recorder)
            defer { runtime.stop() }
            do { try await runtime.send(text: "hello", model: nil); XCTFail("Expected startup failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(script.contains("exit 7") ? "Sign in with codex login" : "Invalid Codex protocol"))
            }
            XCTAssertEqual(recorder.failures.count, 1)
        }
    }

    func testMissingExecutableIsActionableAndInheritedPATHPreserved() throws {
        XCTAssertThrowsError(try AgentProcess.resolve("codex", environment: ["PATH": "/missing-provider-directory"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Install Codex"))
            XCTAssertTrue(error.localizedDescription.contains("PATH"))
        }
        let environment = AgentProcess.environment()
        XCTAssertTrue(environment["PATH"]?.contains("/.local/bin") == true)
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            XCTAssertTrue(environment["PATH"]?.hasPrefix(inherited) == true)
        }
    }

    func testClaudeModelAndEffortChangesRestartSameRuntimeWithResumeAndNilReloadsDefaults() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"request_id":"([^"]+)".*/\1/')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        emit '{"type":"system","subtype":"init","session_id":"stable-session"}'
        emit '{"type":"assistant","message":{"id":"answer","content":[{"type":"text","text":"Done"}]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "original-session")
        defer { runtime.stop() }
        let choices: [(String?, AgentReasoningEffort?)] = [
            ("claude-opus-5-5", .low), ("claude-sonnet-5-5", .medium), (nil, nil)
        ]
        for (model, effort) in choices {
            let idle = expectation(description: "turn completed")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            try await runtime.send(text: "continue", model: model, reasoningEffort: effort)
            await fulfillment(of: [idle], timeout: 5)
        }
        let launches = try fixture.launches()
        XCTAssertEqual(launches.count, 3)
        guard launches.count == 3 else { return }
        XCTAssertTrue(launches[0].contains("--model\nclaude-opus-5-5\n"))
        XCTAssertTrue(launches[0].contains("--effort\nlow\n"))
        XCTAssertTrue(launches[0].contains("--resume\noriginal-session\n"))
        XCTAssertTrue(launches[1].contains("--model\nclaude-sonnet-5-5\n"))
        XCTAssertTrue(launches[1].contains("--effort\nmedium\n"))
        for launch in launches.dropFirst() { XCTAssertTrue(launch.contains("--resume\nstable-session\n")) }
        XCTAssertFalse(launches[2].contains("--effort"))
        XCTAssertFalse(launches[2].contains("--model"))
        let users = try fixture.messages().filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users.count, 3)
        for user in users.dropFirst() { XCTAssertEqual(user["session_id"] as? String, "stable-session") }
        XCTAssertTrue(recorder.failures.isEmpty, "Retired process exit must not fail the replacement process")
    }

    func testClaudeForkForksOnlyUntilItsNewSessionIsKnown() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"request_id":"([^"]+)".*/\1/')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        emit '{"type":"system","subtype":"init","session_id":"forked-session"}'
        emit '{"type":"assistant","uuid":"reply-message","session_id":"forked-session","parent_tool_use_id":null,"message":{"id":"m1","content":[{"type":"text","text":"Done"}]}}'
        emit '{"type":"assistant","uuid":"subagent-message","session_id":"forked-session","parent_tool_use_id":"tool-1","message":{"id":"m2","content":[]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "original-session")
        runtime.prepare(AgentLaunch(forkSource: "original-session", forkPoint: "source-message"))
        defer { runtime.stop() }
        for model in ["claude-opus-5-5", "claude-sonnet-5-5"] {
            let idle = expectation(description: "turn completed")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            try await runtime.send(text: "continue", model: model, reasoningEffort: nil)
            await fulfillment(of: [idle], timeout: 5)
        }
        let launches = try fixture.launches()
        XCTAssertEqual(launches.count, 2)
        guard launches.count == 2 else { return }
        XCTAssertTrue(launches[0].contains("--resume\noriginal-session\n--fork-session\n--resume-session-at\nsource-message\n"))
        XCTAssertTrue(launches[1].contains("--resume\nforked-session\n"))
        XCTAssertFalse(launches[1].contains("--fork-session"))
        XCTAssertFalse(launches[1].contains("--resume-session-at"))
        XCTAssertEqual(Set(recorder.messages), ["reply-message"], "A subagent's messages aren't where the conversation is")
    }

    /// Tab's agent panes know they're in Tab whatever the user installed.
    func testInstructionsReachClaudesSystemPromptAndCodexsDeveloperInstructions() async throws {
        let claudeFixture = try AgentRuntimeFixture(#"""
        take
        id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"request_id":"([^"]+)".*/\1/')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        emit '{"type":"system","subtype":"init","session_id":"s"}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        hold
        """#)
        defer { claudeFixture.remove() }
        let claudeRecorder = AgentRuntimeRecorder()
        let claude = claudeFixture.runtime(.claude, recorder: claudeRecorder)
        claude.prepare(AgentLaunch(instructions: "You are running inside Tab."))
        defer { claude.stop() }
        let answered = expectation(description: "claude turn")
        claudeRecorder.observe = { event in if case .status(.idle) = event { answered.fulfill() } }
        try await claude.send(text: "Hello", model: nil)
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertTrue(try claudeFixture.launches().first?.contains("--append-system-prompt\nYou are running inside Tab.\n") ?? false)

        let codexFixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"one","status":"completed"}}}'
        hold
        """)
        defer { codexFixture.remove() }
        let codexRecorder = AgentRuntimeRecorder()
        let codex = codexFixture.runtime(.codex, recorder: codexRecorder)
        codex.prepare(AgentLaunch(instructions: "You are running inside Tab."))
        defer { codex.stop() }
        let completed = expectation(description: "codex turn")
        codexRecorder.observe = { event in if case .status(.idle) = event { completed.fulfill() } }
        try await codex.send(text: "Hello", model: "gpt-6.1-sol", reasoningEffort: .xhigh)
        await fulfillment(of: [completed], timeout: 5)
        let sent = try codexFixture.messages()
        XCTAssertEqual(sent[2]["method"] as? String, "thread/start")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["developerInstructions"] as? String, "You are running inside Tab.")
    }

    func testCodexForkStartsAThreadForkAndResumesTheNewThreadAfterwards() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "turn completed")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"forked-thread"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"id":"test-model","model":"test-model","isDefault":true,"defaultReasoningEffort":"medium"}]}}'
        take
        emit '{"id":5,"result":{"turn":{"id":"turn"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "old-thread")
        runtime.prepare(AgentLaunch(forkSource: "old-thread"))
        defer { runtime.stop() }
        try await runtime.send(text: "Hello", model: "test-model")
        await fulfillment(of: [idle], timeout: 5)
        let sent = try fixture.messages()
        XCTAssertEqual(sent[2]["method"] as? String, "thread/fork")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["threadId"] as? String, "old-thread")
        XCTAssertEqual(recorder.sessions, ["forked-thread"])
    }

    func testCodexEffortReachesTurnStartAndNilResetsReadRealDefaultsWithoutLosingThread() async throws {

        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"same-thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"one","status":"completed"}}}'
        take
        emit '{"id":4,"result":{"config":{"model":"provider-default","model_reasoning_effort":"medium"}}}'
        take
        emit '{"id":5,"result":{"data":[{"id":"provider-default","model":"provider-default","isDefault":true,"defaultReasoningEffort":"low"}]}}'
        take
        emit '{"id":6,"result":{"turn":{"id":"two"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"two","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        let first = expectation(description: "first turn")
        recorder.observe = { event in if case .status(.idle) = event { first.fulfill() } }
        try await runtime.send(text: "first", model: "gpt-6.1-sol", reasoningEffort: .xhigh)
        await fulfillment(of: [first], timeout: 5)
        let second = expectation(description: "default turn")
        recorder.observe = { event in if case .status(.idle) = event { second.fulfill() } }
        try await runtime.send(text: "default", model: nil, reasoningEffort: nil)
        await fulfillment(of: [second], timeout: 5)
        let messages = try fixture.messages()
        let turns = messages.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(turns.count, 2)
        guard turns.count == 2 else { return }
        XCTAssertEqual(turns[0]["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(turns[0]["effort"] as? String, "xhigh")
        XCTAssertEqual(turns[1]["model"] as? String, "provider-default")
        XCTAssertEqual(turns[1]["effort"] as? String, "medium")
        XCTAssertEqual(turns[0]["threadId"] as? String, turns[1]["threadId"] as? String)
        XCTAssertEqual(try fixture.launches().count, 1, "Codex selections apply per turn without discarding its thread")
    }

    func testMalformedEffortIsRejectedBeforeLaunchingProvider() async throws {
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        do {
            try await runtime.send(text: "not sent", model: nil, reasoningEffort: .init(rawValue: "bad\nvalue"))
            XCTFail("Malformed reasoning must not reach the provider")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not support")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        XCTAssertTrue(recorder.statuses.isEmpty)
    }

    func testClaudePerBlockAssistantFramesRetainAllStreamedText() {
        let recorder = AgentRuntimeRecorder()
        let normalizer = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        normalizer.beginTurn()
        normalizer.receive(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "message"]]])
        normalizer.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Before"]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "text", "text": "Before"]]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "tool_use", "id": "tool", "name": "Read", "input": [:]]]]])
        XCTAssertEqual(recorder.transcript["message"]?.text, "Before")
        normalizer.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": " after"]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "text", "text": " after"]]]])
        normalizer.receive(["type": "result", "result": "Before after"])
        XCTAssertEqual(recorder.transcript["message"]?.text, "Before after")
        XCTAssertEqual(recorder.transcript["message"]?.isComplete, true)
        XCTAssertEqual(recorder.transcript["tool"]?.isComplete, true)
    }

    func testUnsupportedCodexInteractionReceivesRPCErrorUsingStringID() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "idle after rejecting unsupported interaction")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        emit '{"id":"question-1","method":"future/unknownInteraction","params":{"itemId":"not-the-rpc-id","questions":[]}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        let response = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual(response["id"] as? String, "question-1")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertTrue(recorder.transcript.values.contains { $0.kind == .notice })
    }

    func testLargePromptCannotBlockStopWhenChildStopsReading() async throws {
        for provider in AgentChatProvider.allCases {
            let handshake = provider == .claude ? """
            take
            emit '{"type":"control_response","response":{"subtype":"success","request_id":"1"}}'
            """ : """
            take
            emit '{"id":1,"result":{}}'
            take
            take
            emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
            """
            // Replacing the shell avoids descendants inheriting stdout and keeping
            // transport reader threads alive after the fake child is terminated.
            let fixture = try AgentRuntimeFixture(handshake + "\nexec /bin/sleep 30")
            defer { fixture.remove() }
            let recorder = AgentRuntimeRecorder()
            let closed = expectation(description: "stop is not trapped behind a full pipe: \(provider)")
            recorder.observe = { event in if case .status(.closed) = event { closed.fulfill() } }
            let runtime = fixture.runtime(provider, recorder: recorder)
            let started = Date()
            let submission = Task { try await runtime.send(text: String(repeating: "x", count: 2 * 1_024 * 1_024), model: nil) }
            // Give the local handshake time to finish and the write to fill stdin.
            try await Task.sleep(nanoseconds: 200_000_000)
            runtime.stop()
            do { try await submission.value; XCTFail("A full pipe must fail within the write deadline") }
            catch { XCTAssertTrue(error.localizedDescription.contains("stopped reading input")) }
            await fulfillment(of: [closed], timeout: 1)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            XCTAssertEqual(recorder.statuses.last, .closed)
        }
    }

    func testInterruptDuringCodexTurnStartTerminatesStartup() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        hold
        """)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let threadReady = expectation(description: "thread ready, but no turn ID")
        recorder.observe = { event in if case .providerSession = event { threadReady.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        let submission = Task { try await runtime.send(text: "hello", model: nil) }
        await fulfillment(of: [threadReady], timeout: 5)
        try await runtime.interrupt()
        do { try await submission.value; XCTFail("Startup must be cancelled") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped")) }
        XCTAssertEqual(recorder.statuses.last, .closed)
    }
}

final class AgentRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRuntimeEvent] = []
    var observe: (@Sendable (AgentRuntimeEvent) -> Void)?
    func receive(_ event: AgentRuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
        observe?(event)
    }
    private var snapshot: [AgentRuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
    var statuses: [AgentChatStatus] { snapshot.compactMap { if case .status(let value) = $0 { return value }; return nil } }
    var failures: [String] { snapshot.compactMap { if case .failure(let value) = $0 { return value }; return nil } }
    var sessions: [String] { snapshot.compactMap { if case .providerSession(let value) = $0 { return value }; return nil } }
    var messages: [String] { snapshot.compactMap { if case .providerMessage(let value) = $0 { return value }; return nil } }
    var contextUsage: [AgentContextUsage] { snapshot.compactMap { if case .contextUsage(let value) = $0 { return value }; return nil } }
    var resolvedModels: [String] { snapshot.compactMap { if case .resolvedModel(let value) = $0 { return value }; return nil } }
    var subagentLists: [[AgentSubagent]] { snapshot.compactMap { if case .subagents(let value) = $0 { return value }; return nil } }
    var activities: [AgentChatActivity?] { snapshot.compactMap { if case .activity(let value) = $0 { return .some(value) }; return nil } }
    var transcript: [String: AgentChatItem] {
        var items: [String: AgentChatItem] = [:]
        for event in snapshot {
            switch event {
            case .item(let item), .toolItem(let item, _): items[item.id] = item
            case .itemUpdate(let item): if items[item.id] != nil { items[item.id] = item }
            case .textDelta(let id, let text): items[id]?.text += text
            default: break
            }
        }
        return items
    }
}

/// What a revert in `path` restores files in, with `candidates` asked where they work now.
func revertScope(_ path: String, candidates: [Int32] = []) -> AgentRevertScope {
    AgentRevertScope(directory: path, candidates: candidates)
}

struct AgentRuntimeFixture: Sendable {
    let directory: URL
    let script: URL
    let log: URL
    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-agent-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("peer.sh")
        log = directory.appendingPathComponent("input.jsonl")
        let source = """
        #!/bin/sh
        set -eu
        log="$1"
        shift
        printf '%s\\n' '---' >> "$log.args"
        printf '%s\\n' "$@" >> "$log.args"
        take() { IFS= read -r line || exit 0; printf '%s\\n' "$line" >> "$log"; }
        emit() { printf '%s\\n' "$1"; }
        hold() { while IFS= read -r line; do :; done; }
        replay() {
            uuid=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\\([^"]*\\)".*/\\1/p')
            printf '{"type":"user","isReplay":true,"uuid":"%s","message":{"role":"user","content":"echo"}}\\n' "$uuid"
        }
        \(body)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
    }
    func runtime(_ provider: AgentChatProvider, recorder: AgentRuntimeRecorder, resume: String? = nil,
                 timeout: TimeInterval = 3, tools: AgentToolConfiguration? = nil) -> AgentRuntime {
        AgentRuntime(provider: provider, directory: directory.path, resumeSession: resume,
                     launchBuilder: { arguments in
                         .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, log.path] + arguments,
                               environment: AgentProcess.environment())
                     },
                     requestTimeout: timeout, tools: tools, onEvent: { recorder.receive($0) })
    }
    func messages() throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func launches() throws -> [String] {
        try String(contentsOfFile: log.path + ".args", encoding: .utf8).components(separatedBy: "---\n")
            .filter { !$0.isEmpty }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
