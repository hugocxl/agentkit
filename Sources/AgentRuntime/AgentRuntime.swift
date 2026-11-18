import AgentCore
import Foundation
import OSLog
import os

internal enum AgentRuntimeEvent: Sendable {
    case item(AgentChatItem)
    /// Replaces an item the conversation still holds; one it no longer has, as after
    /// trimming, stays gone rather than coming back out of order.
    case itemUpdate(AgentChatItem)
    case toolItem(AgentChatItem, images: [AgentChatAttachment])
    case textDelta(id: String, text: String)
    case status(AgentChatStatus)
    case providerSession(String)
    /// The latest message the provider wrote to its conversation, where a fork made now begins.
    case providerMessage(String)
    case contextUsage(AgentContextUsage)
    /// The agents still running for the conversation, then those finished since the
    /// user's last prompt, replacing the previous list.
    case subagents([AgentSubagent])
    /// An agent's own steps so far, keyed by the tool call that started it.
    case subagentSteps(toolUseID: String, items: [AgentChatItem])
    /// The provider began a turn nobody sent, such as Claude answering a background
    /// agent that finished; `reason` says why when it is known.
    case providerTurn(reason: String)
    /// What holds the provider up now, or nil when nothing does.
    case activity(AgentChatActivity?)
    /// What the turn that just ended used, and why it stopped.
    case turnUsage(AgentTurnUsage)
    case resolvedModel(String)
    case commands([String])
    case commandDescriptors([AgentCommandDescriptor])
    case planMode(Bool)
    case failure(String)
}

/// A follow-up arrived after the provider finished its turn; it needs a turn of its own.
internal struct AgentTurnFinishedError: LocalizedError {
    var errorDescription: String? { "The response has finished. Send the message again to start a follow-up." }
}

/// A follow-up refused because the response it was for is being stopped: it never reached it.
internal struct AgentFollowUpRefused: LocalizedError {
    var errorDescription: String? { "The response was being stopped, so this message didn't reach it." }
}

internal struct AgentRuntimeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All protocol state is confined to queue; process readers never call client code directly.
// Raw control envelope reference: the provider source
// apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.test.ts:2366–2402.
// Codex handshake/request lifecycle: the adjacent CodexAdapterV2.ts,
// ensureInitialized, ensureThread/resumeThread, startNativeTurn, interruptTurn.
internal final class AgentRuntime: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "agentkit.runtime")
    private let provider: AgentChatProvider
    private var suppliedExecutable: URL?
    private let directory: String
    /// The physical folder the current provider process launched in.
    private var launchDirectory: String?
    private var applicationTools: AgentToolConfiguration?
    private var applicationCalls: [String: ApplicationCall] = [:]
    private var applicationCallOrder: [String] = []
    private var applicationTasks: [String: Task<Void, Never>] = [:]
    private var applicationQueue: [String] = []
    private var applicationSerialID: String?
    private var applicationLeases: [UUID: AgentToolExecutionContext] = [:]
    private var cancellingApplicationTools = false
    private var applicationOnly: Bool { applicationTools?.applicationOnly == true }
    private var resumeSession: String?
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private let launchOverride: AgentProcess.Launch?
    private let launchBuilder: (@Sendable ([String]) -> AgentProcess.Launch)?
    private let requestTimeout: TimeInterval
    private var process: AgentProcess?
    /// Processes replaced by a restart, until they exit.
    private(set) var replaced: [AgentProcess] = []
    /// Its provider processes with the folders they run in, each as it was at its launch,
    /// and launches reserved before their process starts; once refused, it launches none.
    private struct Launches {
        var running: [(process: AgentProcess, folder: AgentFolder)] = []
        var reserved: [UUID: AgentFolder] = [:]
        var refused = false
    }
    private let launches = OSAllocatedUnfairLock(initialState: Launches())
    private var closed = false
    private var failed = false
    private var busy = false
    /// The user stopped the running turn. Providers end such a turn with an error
    /// (Claude's `error_during_execution` result); that error is the stop, not a failure.
    private var interruptRequested = false
    /// Follow-ups written to Claude that it has not echoed back yet. Claude folds a
    /// follow-up into the running turn at a tool boundary, or else answers it in
    /// its own turn after the current result; only the echo tells which.
    private var unconsumedClaudeInputs: Set<String> = []
    /// Retries the provider announced since its last successful output.
    private var retryAttempts = 0
    /// The running turn is one the provider began on its own, such as Claude answering
    /// a background agent that finished.
    private var providerInitiatedTurn = false
    /// Sends that arrived during a provider-initiated turn; they start when it ends,
    /// so a queued prompt's delivery is never refused or folded into that turn.
    private var deferredSends: [(Error?) -> Void] = []
    private var ready = false
    private var sequence = 0
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var approvals: [String: [String: Any]] = [:]
    private var questions: [String: (form: AgentQuestionnaire, wire: [String: Any])] = [:]
    private var answeredQuestions: Set<String> = []
    private var completedApprovals: Set<String> = []
    /// The cards of pending requests that carry offered decisions, by item ID.
    private var interactions: [String: AgentApprovalRequest] = [:]
    /// Decisions sent, by item ID, so a repeated decision is answered as already sent.
    private var decided: [String: String] = [:]
    /// Child agents' Codex threads, with the transcript row that started each.
    private var childThreads: [String: String] = [:]
    /// The latest usage-limit reset Codex reported, for a turn its limit stops.
    private var codexRateLimitReset: Date?
    private var completedApprovalOrder: [String] = []
    private var threadID: String?
    private var turnID: String?
    private var model: String?
    private var reasoningEffort: AgentReasoningEffort?
    private var hasSubmittedTurn = false
    private var processGeneration = UUID()
    private var accessMode: AgentAccessMode = .standard
    private var launch = AgentLaunch()
    private lazy var claude = ClaudeAgentRuntime(onEvent: onEvent)
    private lazy var codex = CodexAgentRuntime(onEvent: onEvent)

    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         executable: URL? = nil, tools: AgentToolConfiguration? = nil, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.suppliedExecutable = executable
        self.applicationTools = tools
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = nil
        launchBuilder = nil
        requestTimeout = 30
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    /// Test seam uses an actual local fake subprocess, never a provider/account.
    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         launch: AgentProcess.Launch, requestTimeout: TimeInterval = 30,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = launch
        launchBuilder = nil
        self.requestTimeout = requestTimeout
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    /// Replays the actual generated provider arguments against a synthetic subprocess.
    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         launchBuilder: @escaping @Sendable ([String]) -> AgentProcess.Launch, requestTimeout: TimeInterval = 30, tools: AgentToolConfiguration? = nil,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = nil
        self.launchBuilder = launchBuilder
        self.applicationTools = tools
        self.requestTimeout = requestTimeout
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort? = nil) async throws {
        try await send(text: text, model: model, reasoningEffort: reasoningEffort, attachments: [])
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.startSend(text: text, model: model, reasoningEffort: reasoningEffort, attachments: attachments,
                               continuation: continuation)
            }
        }
    }

    private func startSend(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
                           attachments: [StagedAgentAttachment], continuation: CheckedContinuation<Void, Error>) {
                guard !self.closed, !self.failed else {
                    continuation.resume(throwing: AgentRuntimeError("Agent is closed or failed; open a new agent pane to resume."))
                    return
                }
                if self.busy, self.providerInitiatedTurn {
                    self.deferredSends.append { error in
                        if let error { continuation.resume(throwing: error); return }
                        self.startSend(text: text, model: model, reasoningEffort: reasoningEffort,
                                       attachments: attachments, continuation: continuation)
                    }
                    return
                }
                guard !self.busy else {
                    continuation.resume(throwing: AgentRuntimeError("Wait for the current turn or interrupt it first."))
                    return
                }
                if let reasoningEffort,
                   !reasoningEffort.isAccepted(provider: self.provider, model: model) {
                    continuation.resume(throwing: AgentRuntimeError("This provider/model does not support \(reasoningEffort.title) reasoning."))
                    return
                }
                do {
                    if self.provider == .claude, self.ready,
                       model != self.model || reasoningEffort != self.reasoningEffort {
                        try self.restartClaudeSelection()
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                self.busy = true
                self.interruptRequested = false
                self.onEvent(.status(.working))
                let submit: (Result<[String: Any], Error>) -> Void = { result in
                    do {
                        _ = try result.get()
                        try self.submit(text: text, model: model, reasoningEffort: reasoningEffort,
                                        attachments: attachments, continuation: continuation)
                    } catch {
                        self.fail(error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
                do {
                    if self.ready { submit(.success([:])); return }
                    try self.start(model: model, reasoningEffort: reasoningEffort, completion: submit)
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
    }

    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        try await steer(text: text, attachments: attachments, delivery: AgentDelivery())
    }

    func steer(text: String, attachments: [StagedAgentAttachment], delivery: AgentDelivery) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.closed, !self.failed else {
                        throw AgentRuntimeError("Agent is closed or failed; open a new agent pane to resume.")
                    }
                    guard self.busy, self.ready else { throw AgentTurnFinishedError() }
                    // In order with Stop on this queue: once a stop is asked for, nothing joins the turn.
                    guard !self.interruptRequested else { throw AgentFollowUpRefused() }
                    // Stop cancels the hand-over from the sessions queue: whichever comes first
                    // decides, so a stopped follow-up never joins a later turn either.
                    guard delivery.handOver() else { throw AgentFollowUpRefused() }
                    if self.provider == .claude {
                        let input = UUID().uuidString.lowercased()
                        try self.write(["type": "user", "message": ["role": "user",
                            "content": AgentAttachments.claudeContent(text: text, attachments: attachments)],
                            "parent_tool_use_id": NSNull(), "session_id": self.claude.sessionID ?? self.resumeSession ?? "",
                            "uuid": input])
                        self.unconsumedClaudeInputs.insert(input)
                        continuation.resume()
                    } else {
                        guard let thread = self.threadID, let turn = self.turnID else {
                            throw AgentRuntimeError("The response is still starting. Try sending again shortly.")
                        }
                        try self.request("turn/steer", params: ["threadId": thread, "expectedTurnId": turn,
                            "input": AgentAttachments.codexInput(text: text, attachments: attachments)]) { result in
                            do { _ = try result.get(); continuation.resume() }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func restartClaudeSelection() throws {
        // the source renderer's query identity includes model and effort. Clearing effort must
        // reload provider settings, not silently retain the previous override.
        guard let session = claude.sessionID ?? resumeSession else {
            throw AgentRuntimeError("Claude has not supplied a session ID to resume after changing model or effort.")
        }
        processGeneration = UUID()
        cancelApplicationTools()
        applicationCalls.removeAll(); applicationCallOrder.removeAll()
        discardProcess()
        let stopped = claude.endProcess()
        if stopped > 0 {
            onEvent(.item(AgentChatItem(kind: .notice, text: Self.stoppedAgents(stopped, because: "the model or reasoning effort changed, which restarts Claude"))))
        }
        pending.removeAll() // Only non-awaited interrupt acknowledgments can remain after an idle turn.
        resumeSession = session
        ready = false
    }

    private func start(model: String?, reasoningEffort: AgentReasoningEffort?,
                       completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        var environment = AgentProcess.environment()
        // A nested SDK process is intentional, not an interactive Claude session.
        environment.removeValue(forKey: "CLAUDECODE")
        // Only terminals are Tab sessions; an inherited one isn't this agent's.
        environment.removeValue(forKey: "TAB_SESSION_ID")
        environment.merge(launch.environment) { _, tab in tab }

        if let path = launch.path { environment["PATH"] = [path, environment["PATH"]].compactMap { $0 }.joined(separator: ":") }
        let forking = launch.forkSource != nil && resumeSession == launch.forkSource
        var arguments = provider == .claude
            ? ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
            : ["app-server"]
        if provider == .claude {
            appliedClaudePlanMode = false
            if let resumeSession { arguments += ["--resume", resumeSession] }
            if forking {
                arguments.append("--fork-session")
                if let point = launch.forkPoint { arguments += ["--resume-session-at", point] }
            }
            if let model { arguments += ["--model", model] }
            if let reasoningEffort { arguments += ["--effort", claudeWireEffort(reasoningEffort, model: model)] }
            if let instructions = self.launch.instructions { arguments += [applicationOnly ? "--system-prompt" : "--append-system-prompt", instructions] }
            if applicationTools != nil {
                arguments += ["--mcp-config", #"{"mcpServers":{"agentkit":{"type":"sdk","name":"agentkit"}}}"#,
                              "--allowedTools", "mcp__agentkit__*"]
                if applicationOnly { arguments += ["--strict-mcp-config", "--tools", "", "--setting-sources", ""] }
            }
            self.model = model
            self.reasoningEffort = reasoningEffort
        }
        if provider == .codex, applicationOnly {
            arguments += ["-c", "features.shell_tool=false", "-c", "features.multi_agent=false", "-c", "web_search=\"disabled\""]
        }
        let launch = try launchBuilder?(arguments) ?? launchOverride ?? AgentProcess.Launch(
            executable: suppliedExecutable ?? AgentProcess.resolve(provider == .claude ? "claude" : "codex", environment: environment),
            arguments: arguments, environment: environment)
        let generation = processGeneration
        // One physical folder per launch: the identity recorded, the process's folder and the
        // cwd Codex is given all name it, however a link on the way changes meanwhile.
        let launchDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        // Reserved before the process exists, so a revert in its folder finds it, and refused
        // once the runtime is retired, so none launches after a revert found nothing.
        let folder = AgentFolder(launchDirectory), reservation = UUID()
        guard launches.withLock({ launches -> Bool in
            guard !launches.refused else { return false }
            launches.reserved[reservation] = folder
            return true
        }) else { throw AgentRuntimeError("Agent stopped.") }
        defer { launches.withLock { _ = $0.reserved.removeValue(forKey: reservation) } }
        let started = try AgentProcess(launch: launch, directory: launchDirectory, onLine: { [weak self] line in
            self?.queue.async { [weak self] in
                guard let self, self.processGeneration == generation else { return }
                self.receive(line)
            }
        }, onExit: { [weak self] code, stderr in
            self?.queue.async { [weak self] in
                guard let self, !self.closed, !self.failed, self.processGeneration == generation else { return }
                self.fail("\(self.provider.name) exited (\(code)). \(stderr.isEmpty ? "Check CLI installation and authentication; update the CLI if stream-json/app-server is unsupported." : stderr)")
            }
        })
        launches.withLock {
            $0.running.removeAll { !$0.process.isRunning }
            $0.running.append((started, folder))
        }
        process = started
        self.launchDirectory = launchDirectory
        if provider == .claude {
            try request("initialize", params: applicationTools == nil ? ["hooks": [:]] : ["hooks": [:], "sdkMcpServers": ["agentkit"]], completion: { result in
                if case .success(let response) = result {
                    self.ready = true
                    let descriptors = AgentCommandDiscovery.descriptors(response["commands"] as? [[String: Any]] ?? [])
                    self.onEvent(.commandDescriptors(Array(descriptors.prefix(256))))
                }
                completion(result)
            })
        } else {
            try request("initialize", params: ["clientInfo": ["name": "agentkit", "version": AgentKitVersion.current], "capabilities": ["experimentalApi": true]], completion: { result in
                do {
                    _ = try result.get()
                    try self.write(["method": "initialized"])
                    var params: [String: Any] = ["cwd": self.launchDirectory ?? self.directory,
                        "approvalPolicy": self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request",
                        "sandbox": self.accessMode == .fullAccess ? "danger-full-access" : self.accessMode == .ask ? "read-only" : "workspace-write"]
                    if self.applicationOnly { params["approvalPolicy"] = "never"; params["sandbox"] = "read-only" }
                    if self.resumeSession == nil, let tools = self.applicationTools { params["dynamicTools"] = tools.codexDefinitions }
                    if let model { params["model"] = model }
                    if let instructions = self.launch.instructions { params["developerInstructions"] = instructions }
                    if let resumeSession = self.resumeSession { params["threadId"] = resumeSession }
                    let method = self.resumeSession == nil ? "thread/start" : forking ? "thread/fork" : "thread/resume"
                    try self.request(method, params: params) { result in
                        do {
                            let response = try result.get()
                            guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else {
                                throw AgentRuntimeError("Codex did not return a thread ID.")
                            }
                            self.threadID = id
                            if forking { self.resumeSession = id }
                            self.ready = true
                            self.onEvent(.providerSession(id))
                            if let model = response["model"] as? String { self.onEvent(.resolvedModel(model)) }
                            completion(.success(response))
                        } catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            })
        }
    }

    private func submit(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
                        attachments: [StagedAgentAttachment],
                        continuation: CheckedContinuation<Void, Error>) throws {
        if provider == .claude {
            let submitUser: (Result<[String: Any], Error>) -> Void = { result in
                do {
                    _ = try result.get()
                    self.claude.beginTurn()
                    self.claude.clearFinishedSubagents()
                    try self.write(["type": "user", "message": ["role": "user", "content": AgentAttachments.claudeContent(text: text, attachments: attachments)],
                                     "parent_tool_use_id": NSNull(), "session_id": self.claude.sessionID ?? self.resumeSession ?? ""])
                    self.hasSubmittedTurn = true
                    continuation.resume()
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
            if planMode != appliedClaudePlanMode {
                try request("set_permission_mode", params: ["mode": planMode ? "plan" : "default"]) { result in
                    if case .success = result { self.appliedClaudePlanMode = self.planMode }
                    submitUser(result)
                }
            } else { submitUser(.success([:])) }
        } else {
            guard let threadID else { throw AgentRuntimeError("Codex thread is not initialized.") }
            let invocation = AgentSlashCommand(text: text)
            if let command = invocation, ["compact", "review"].contains(command.name) {
                if let error = command.validationError(provider: .codex, commands: ["compact", "review"], hasAttachments: !attachments.isEmpty) {
                    throw AgentRuntimeError(error)
                }
                guard attachments.isEmpty else { throw AgentRuntimeError("This command does not accept attachments.") }
                let method = command.name == "compact" ? "thread/compact/start" : "review/start"
                var params: [String: Any] = ["threadId": threadID]
                if command.name == "review" {
                    var target = ["type": "uncommittedChanges"]
                    if command.arguments.hasPrefix("branch ") { target = ["type": "baseBranch", "branch": String(command.arguments.dropFirst(7)).trimmingCharacters(in: .whitespaces)] }
                    if command.arguments.hasPrefix("commit ") { target = ["type": "commit", "sha": String(command.arguments.dropFirst(7)).trimmingCharacters(in: .whitespaces)] }
                    params["target"] = target; params["delivery"] = "inline"
                }
                try request(method, params: params) { result in
                    do { _ = try result.get(); continuation.resume() }
                    catch { self.fail(error.localizedDescription); continuation.resume(throwing: error) }
                }
                return
            }
            try codexSelection(model: model, reasoningEffort: reasoningEffort) { selection in
                do {
                    let (wireModel, effort) = try selection.get()
                    var params: [String: Any] = ["threadId": threadID, "input": AgentAttachments.codexInput(text: text, attachments: attachments)]
                    // Source codexRuntimeModeTurnDefaults: explicitly reset on every
                    // turn so leaving Full access restores native prompting/sandboxing.
                    params["approvalPolicy"] = self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request"
                    params["sandboxPolicy"] = ["type": self.accessMode == .fullAccess ? "dangerFullAccess" : self.accessMode == .ask ? "readOnly" : "workspaceWrite"]
                    if self.applicationOnly {
                        params["approvalPolicy"] = "never"
                        params["sandboxPolicy"] = ["type": "readOnly"]
                    }
                    if let wireModel { params["model"] = wireModel }
                    if let effort { params["effort"] = effort }
                    if self.planModeConfigured, let collaborationModel = wireModel {
                        params["collaborationMode"] = ["mode": self.planMode ? "plan" : "default",
                            "settings": ["model": collaborationModel, "reasoning_effort": effort as Any? ?? NSNull(),
                                         "developer_instructions": NSNull()]]
                    } else if self.planMode {
                        throw AgentRuntimeError("Choose an explicit model before starting plan mode.")
                    }
                    try self.request("turn/start", params: params) { result in
                        do {
                            let response = try result.get()
                            self.model = model
                            if let wireModel { self.onEvent(.resolvedModel(wireModel)) }
                            self.reasoningEffort = reasoningEffort
                            self.hasSubmittedTurn = true
                            if self.busy, let turn = response["turn"] as? [String: Any] { self.turnID = turn["id"] as? String }
                            continuation.resume()
                        } catch {
                            self.fail(error.localizedDescription)
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func claudeWireEffort(_ effort: AgentReasoningEffort, model: String?) -> String {
        let model = (model ?? "").lowercased().replacingOccurrences(of: ".", with: "-")
        // Source manifest adapter.claudeCode.effortMap for the two legacy profiles.
        if effort == .xhigh, model.contains("opus-4-7") { return "max" }
        if effort == .max, model.contains("sonnet-4-6") { return "high" }
        return effort.rawValue
    }

    private func codexSelection(model: String?, reasoningEffort: AgentReasoningEffort?,
                                completion: @escaping (Result<(String?, String?), Error>) -> Void) throws {
        let resumedDefaults = !hasSubmittedTurn && resumeSession != nil
        let resetModel = model == nil && (planModeConfigured || resumedDefaults || (hasSubmittedTurn && self.model != nil))
        let resetEffort = reasoningEffort == nil && (resumedDefaults
            || (hasSubmittedTurn && (self.reasoningEffort != nil || model != self.model)))
        guard resetModel || resetEffort else {
            completion(.success((model, reasoningEffort?.rawValue)))
            return
        }
        // Codex turn/start overrides persist to subsequent turns. Omitting a
        // cleared selector would keep its old value. Read real provider defaults.
        try request("config/read", params: ["includeLayers": false, "cwd": launchDirectory ?? directory]) { result in
            do {
                let config = try result.get()["config"] as? [String: Any] ?? [:]
                try self.codexModels { result in
                    do {
                        let models = try result.get()
                        let defaultModel = config["model"] as? String
                            ?? models.first(where: { $0["isDefault"] as? Bool == true })?["model"] as? String
                        let effectiveModel = model ?? defaultModel
                        let descriptor = models.first { ($0["model"] as? String ?? $0["id"] as? String) == effectiveModel }
                        let defaultEffort = config["model_reasoning_effort"] as? String
                            ?? descriptor?["defaultReasoningEffort"] as? String
                        guard (!resetModel || defaultModel != nil), (!resetEffort || defaultEffort != nil) else {
                            throw AgentRuntimeError("Codex did not report its default model/effort. Cannot safely reset this selection; choose explicit values.")
                        }
                        completion(.success((resetModel ? defaultModel : model,
                                             resetEffort ? defaultEffort : reasoningEffort?.rawValue)))
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func codexModels(cursor: String? = nil, rows: [[String: Any]] = [],
                             cursors: Set<String> = [],
                             completion: @escaping (Result<[[String: Any]], Error>) -> Void) throws {
        var params: [String: Any] = ["includeHidden": false, "limit": 100]
        if let cursor { params["cursor"] = cursor }
        try request("model/list", params: params) { result in
            do {
                let response = try result.get()
                let models = rows + (response["data"] as? [[String: Any]] ?? [])
                guard models.count <= 4096 else { throw AgentRuntimeError("Codex model catalog is too large.") }
                if let next = response["nextCursor"] as? String, !next.isEmpty {
                    guard cursors.count < 32, !cursors.contains(next) else {
                        throw AgentRuntimeError("Codex model catalog pagination did not finish.")
                    }
                    try self.codexModels(cursor: next, rows: models, cursors: cursors.union([next]), completion: completion)
                } else { completion(.success(models)) }
            } catch { completion(.failure(error)) }
        }
    }

    private var planMode = false
    /// Tools the user allowed for the rest of the conversation; never questions or plans.
    private var alwaysAllowedTools: Set<String> = []
    private var planModeConfigured = false
    private var appliedClaudePlanMode = false

    func setPlan(_ enabled: Bool) async throws {
        try await perform { self.planMode = enabled; self.planModeConfigured = true }
    }

    func approve(request: String, allow: Bool) async throws {
        try await approve(request: request, allow: allow, always: false, reason: nil)
    }

    func approve(request: String, allow: Bool, always: Bool, reason: String?) async throws {
        try await perform {
            // A mode change may have answered the same request while a manual
            // response was in flight. Return the real, already-completed outcome.
            if self.approvals[request] == nil, self.completedApprovals.contains(request) { return }
            guard let approval = self.approvals[request] else { throw AgentRuntimeError("Approval is no longer pending.") }
            if reason != nil, self.provider != .claude {
                throw AgentRuntimeError("Codex can't take a reason with a denial.")
            }
            guard always else {
                try self.resolveApproval(request, allow: allow, reason: reason)
                return
            }
            guard allow, self.provider == .claude, let tool = approval["tool_name"] as? String,
                  AgentApprovalScope.canAlwaysAllow(tool) else {
                throw AgentRuntimeError("This request can only be allowed once.")
            }
            self.alwaysAllowedTools.insert(tool)
            try self.resolveApproval(request, allow: true)
            self.onEvent(.item(AgentChatItem(kind: .notice, text: "\(tool) runs without asking for the rest of this conversation.")))
            try self.allowPendingAutomatically()
        }
    }

    func setAlwaysAllowed(_ tools: Set<String>) async throws {
        try await perform {
            self.alwaysAllowedTools = tools
            try self.allowPendingAutomatically()
        }
    }

    private func allowPendingAutomatically() throws {
        for id in approvals.keys.sorted() {
            guard let approval = approvals[id], automaticallyAllows(approval),
                  interactions[id].map({ $0.only(.allowOnce) != nil }) ?? true else { continue }
            try resolveApproval(id, allow: true, automatic: true)
        }
    }

    /// Changes host approvals immediately without restarting an active turn.
    /// Codex native prompting/sandbox changes are sent on its next turn/start.
    func setAccess(_ mode: AgentAccessMode) async throws {
        try await perform {
            self.accessMode = mode
            try self.allowPendingAutomatically()
        }
    }

    private func automaticallyAllows(_ approval: [String: Any]) -> Bool {
        let tool = approval["tool_name"] as? String
        // An MCP server's request is the user's to answer, whatever the access mode.
        guard tool != "AskUserQuestion", tool != "ExitPlanMode", approval["elicitation"] == nil else { return false }
        if provider == .claude, let tool, alwaysAllowedTools.contains(tool) { return true }
        switch accessMode {
        case .ask: return false
        case .fullAccess: return true
        case .standard:
            guard provider == .claude, let tool else { return false }
            return ["Read", "Glob", "Grep", "WebSearch", "WebFetch"].contains(tool)
        }
    }

    private func resolveApproval(_ id: String, allow: Bool, automatic: Bool = false, reason: String? = nil) throws {
        guard let approval = approvals[id] else { throw AgentRuntimeError("Approval is no longer pending.") }
        if provider == .claude {
            let input = approval["input"] as? [String: Any] ?? [:]
            var response: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if allow { response["updatedInput"] = input }
            else { response["message"] = reason.isEmpty ? "User declined tool execution." : "User declined tool execution: " + reason }
            if let toolID = approval["tool_use_id"] { response["toolUseID"] = toolID }
            try write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
        } else if let interaction = interactions[id] {
            // Plain Allow and Deny, from a client that predates offered decisions or the access
            // mode, send the provider's own one-time answer only when it was offered.
            let wanted: [AgentApprovalDecision.Kind] = allow ? [.allowOnce] : [.decline, .cancel]
            guard let decision = wanted.lazy.compactMap({ interaction.only($0) }).first else {
                throw AgentRuntimeError("Codex did not offer a one-time \(allow ? "approval" : "rejection"). Choose one of the offered answers or stop the turn.")
            }
            try writeCodexDecision(id, approval: approval, decision: decision.id)
            finishDecision(id, approval: approval, decision: decision, automatic: automatic)
            return
        } else {
            let available = (approval["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
            let decision = allow ? "accept" : available?.contains("decline") == false ? "cancel" : "decline"
            guard available == nil || available?.contains(decision) == true else {
                throw AgentRuntimeError("Codex did not offer a one-time \(allow ? "approval" : "rejection"). This interaction is unsupported; interrupt the turn instead.")
            }
            try write(["id": approval["wireID"] ?? id, "result": ["decision": decision]])
        }
        if allow, approval["tool_name"] as? String == "ExitPlanMode" {
            planMode = false; appliedClaudePlanMode = false
            onEvent(.planMode(false))
        }
        approvals.removeValue(forKey: id)
        if id.utf8.count <= 1024, completedApprovals.insert(id).inserted {
            completedApprovalOrder.append(id)
            if completedApprovalOrder.count > 512 {
                completedApprovals.remove(completedApprovalOrder.removeFirst())
            }
        }
        let text = automatic ? "Automatically approved" : allow ? "Approved" : "Declined"
        if var interaction = interactions.removeValue(forKey: id) {
            let kind: AgentApprovalDecision.Kind = allow ? .allowOnce : .decline
            interaction.chosen = interaction.only(kind)?.id ?? (allow ? "allow" : "deny")
            interaction.outcome = automatic ? .automatic : .decided
            onEvent(.item(AgentChatItem(id: id, kind: .approval, text: text, interaction: interaction)))
        } else {
            onEvent(.item(AgentChatItem(id: id, kind: .approval, text: text)))
        }
        onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    func interrupt() async throws {
        try await perform {
            guard self.busy else { return }
            self.interruptRequested = true
            self.cancelApplicationTools()
            if self.provider == .claude {
                if !self.unconsumedClaudeInputs.isEmpty {
                    self.resumeSession = self.claude.sessionID ?? self.resumeSession
                    self.processGeneration = UUID()
                    self.discardProcess()
                    let stopped = self.claude.endProcess()
                    if stopped > 0 {
                        self.onEvent(.item(AgentChatItem(kind: .notice, text: Self.stoppedAgents(stopped, because: "Claude was restarted to stop the response"))))
                    }
                    self.ready = false
                    let count = self.unconsumedClaudeInputs.count
                    self.unconsumedClaudeInputs.removeAll()
                    self.onEvent(.item(AgentChatItem(kind: .notice, text: "Stopped Claude and cancelled \(count) unconsumed follow-up(s). Delivered prompts remain in the transcript; review them before retrying.")))
                    self.resolvePending(AgentRuntimeError("Interrupted"))
                    self.completeTurn()
                    return
                }
                try self.request("interrupt", params: [:], completion: self.interruptAcknowledged)
            } else if let threadID = self.threadID, let turnID = self.turnID {
                try self.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
                                 completion: self.interruptAcknowledged)
            } else { self.close() }
        }
    }

    /// A refused or unanswered stop isn't a failure: the turn may have just finished, and one
    /// that keeps running is stopped by its session after a bounded wait.
    private func interruptAcknowledged(_ result: Result<[String: Any], Error>) {
        if case .failure(let error) = result {
            AgentLog.error("\(provider.name) did not acknowledge an interrupt: \(error.localizedDescription)")
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) { close() }
        else { queue.sync { self.close() } }
    }

    // Read without the runtime's queue, which may be held by a write to a provider that
    // stopped reading.
    func mayRun(in scope: AgentRevertScope) -> Bool {
        launches.withLock { launches in
            launches.reserved.values.contains { scope.holds($0) }
                || launches.running.contains { scope.holds($0.folder, process: $0.process.processIdentifier) && $0.process.isRunning }
        }
    }

    func isStopping(in scope: AgentRevertScope) -> Bool {
        launches.withLock { $0.running.contains { scope.holds($0.folder, process: $0.process.processIdentifier) && $0.process.isStopping } }
    }

    func providerProcesses() -> [Int32] {
        launches.withLock { $0.running.filter { $0.process.isRunning }.map { $0.process.processIdentifier } }
    }

    func refuseLaunches() { launches.withLock { $0.refused = true } }

    /// Stops, then waits until the provider process, and any it replaced, has exited.
    func terminate() {
        stop()
        let processes = DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self)
            ? [process].compactMap { $0 } + replaced : queue.sync { [process].compactMap { $0 } + replaced }
        for process in processes { process.waitForExit() }
    }

    /// Stops the provider process this runtime is about to replace, keeping it until it
    /// has exited so `terminate()` can wait for it. Runs on the runtime's queue.
    private func discardProcess() {
        guard let process else { return }
        process.stop()
        replaced.removeAll { !$0.isRunning }
        replaced.append(process)
        self.process = nil
    }

    private func close() {
        guard !closed else { return }
        closed = true
        cancelApplicationTools()
        process?.stop()
        resolvePending(AgentRuntimeError("Agent stopped."))
        resolveDeferredSends(AgentRuntimeError("Agent stopped."))
        finishApprovals()
        onEvent(.status(.closed))
    }

    func prepare(_ launch: AgentLaunch) {
        queue.sync { self.launch = launch }
    }

    private func perform(_ action: @escaping () throws -> Void) async throws {

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.closed, !self.failed else { throw AgentRuntimeError("Agent is not running.") }
                    try action()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let process, !closed, !failed else { throw AgentRuntimeError("Agent process is not running.") }
        try process.write(message)
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        sequence += 1
        let id = String(sequence)
        if provider == .claude {
            var request = params
            request["subtype"] = method
            try write(["type": "control_request", "request_id": id, "request": request])
        } else { try write(["id": sequence, "method": method, "params": params]) }
        pending[id] = completion
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: id) else { return }
            completion(.failure(AgentRuntimeError("\(self.provider.name) timed out responding to \(method). Check CLI authentication and updates; on macOS, also check whether system security is blocking the executable.")))
        }
    }

    /// Handles one provider line as if its process wrote it; replay tests feed captured shapes.
    func replay(_ line: String) { queue.sync { receive(Data(line.utf8)) } }

    private func receive(_ data: Data) {
        guard !closed, !failed else { return }
        do {
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentRuntimeError("Expected a JSON object from agent.")
            }
            let source = AgentProviderJSON(data: data)
            if provider == .claude { try receiveClaude(message, source: source) } else { try receiveCodex(message, source: source) }
        } catch { fail("Invalid \(provider.name) protocol: \(error.localizedDescription)") }
    }

    private func receiveClaude(_ message: [String: Any], source: AgentProviderJSON) throws {
        let type = message["type"] as? String
        if type == "control_response", let response = message["response"] as? [String: Any],
           let id = response["request_id"] as? String, let completion = pending.removeValue(forKey: id) {
            if response["subtype"] as? String == "error" {
                completion(.failure(AgentRuntimeError(response["error"] as? String ?? "Claude control request failed.")))
            } else { completion(.success(response["response"] as? [String: Any] ?? [:])) }
            return
        }
        if type == "control_request", let id = message["request_id"] as? String,
           let request = message["request"] as? [String: Any] {
            if request["subtype"] as? String == "mcp_message", applicationTools != nil {
                try receiveApplicationMCP(request, requestID: id)
                return
            }
            if applicationOnly, request["subtype"] as? String == "can_use_tool" {
                let name = request["tool_name"] as? String ?? ""
                let allowed = applicationTools?.definitions.contains { "mcp__agentkit__" + $0.name == name } == true
                var body: [String: Any] = ["behavior": allowed ? "allow" : "deny"]
                if allowed { body["updatedInput"] = request["input"] ?? [:] }
                else { body["message"] = "This application uses its registered tools for editing." }
                try write(applicationMCPResponse(id, body))
                return
            }
            guard request["subtype"] as? String == "can_use_tool" else {
                try write(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                            "error": "This application supports tool approvals only; this interactive request is unsupported."]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Claude interaction: \(request["subtype"] as? String ?? "unknown")")))
                return
            }
            if request["tool_name"] as? String == "AskUserQuestion" {
                let input = request["input"] as? [String: Any] ?? [:]
                try presentQuestions(id: id, form: AgentQuestionParser.parse(input, claude: true), wire: request)
                return
            }
            if request["tool_name"] as? String == "ExitPlanMode" {
                // Capture actual supplied proposal content without changing this
                // native provider's existing approval/permission behavior.
                claude.capturePlan(nativeID: request["tool_use_id"] as? String ?? id, name: "ExitPlanMode", input: request["input"])
            }
            approvals[id] = request
            if automaticallyAllows(request) {
                try resolveApproval(id, allow: true, automatic: true)
                return
            }
            let tool = request["tool_name"] as? String ?? "Tool approval"
            // A subagent's request names the agent; its card says so and offers the same answers.
            let interaction = (request["agent_id"] as? String).map { agent in
                claudeInteraction(id: id, tool: tool, origin: AgentRequestOrigin(agentID: agent, name: request["agent_type"] as? String))
            }
            if let interaction { interactions[id] = interaction }
            onEvent(.item(AgentChatItem(id: id, kind: .approval, text: tool,
                                       detail: agentRuntimeJSON(request["input"]), isComplete: false,
                                       workContext: .init(requestKind: agentClaudeApprovalKind(tool)), interaction: interaction)))
            onEvent(.status(.waiting))
            return
        }
        if type == "control_cancel_request", let id = message["request_id"] as? String {
            if questions.removeValue(forKey: id) != nil || approvals.removeValue(forKey: id) != nil {
                settle(id, text: "Cancelled", outcome: .resolvedElsewhere)
                onEvent(.status(approvals.isEmpty && questions.isEmpty ? .working : .waiting))
            }
            return
        }
        if type == "user", message["isReplay"] as? Bool == true, let input = message["uuid"] as? String {
            unconsumedClaudeInputs.remove(input.lowercased())
        }
        // Output with no turn running is a turn Claude began itself, such as its answer
        // to a background agent that finished. It gets a turn, so it can be watched and stopped.
        if !busy, ready, type == "stream_event" || type == "assistant",
           message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull {
            busy = true
            providerInitiatedTurn = true
            interruptRequested = false
            claude.beginTurn()
            let reason = claude.lastFinishedBackground.map { "Background agent “\($0.description)” finished" }
                ?? "Claude continued on its own"
            onEvent(.providerTurn(reason: reason))
            onEvent(.status(.working))
        }
        claude.interrupted = interruptRequested
        if type == "rate_limit_event", let info = message["rate_limit_info"] as? [String: Any] {
            onEvent(.activity(Self.rateLimitActivity(info)))
        }
        claude.receive(message, source: source)
        if type == "result" {
            if message["is_error"] as? Bool == true, !interruptRequested {
                fail((message["errors"] as? [String])?.joined(separator: "\n") ?? message["result"] as? String ?? "Claude turn failed.")
            } else { completeTurn() }
        }
    }

    private func receiveCodex(_ message: [String: Any], source: AgentProviderJSON) throws {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if method == nil, let wireID = message["id"], let completion = pending.removeValue(forKey: agentRuntimeID(wireID)) {
            if let error = message["error"] as? [String: Any] {
                completion(.failure(AgentRuntimeError(error["message"] as? String ?? "Codex request failed.")))
            } else { completion(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        if let method, let wireID = message["id"] {
            let id = agentProviderRequestKey(wireID)
            if method == "item/tool/call" {
                if let thread = params["threadId"] as? String, thread != threadID {
                    try write(["id": wireID, "result": Self.codexApplicationResult(.failure("Tool belongs to another thread."))]); return
                }
                if let turn = params["turnId"] as? String, turn != turnID {
                    try write(["id": wireID, "result": Self.codexApplicationResult(.failure("Tool belongs to an inactive turn."))]); return
                }
                let call = AgentToolCall(id: params["callId"] as? String ?? id, name: params["tool"] as? String ?? "",
                                         arguments: try AgentJSONValue(foundation: params["arguments"] ?? [:]))
                runApplicationTool(call) { result in ["id": wireID, "result": Self.codexApplicationResult(result)] }
                return
            }
            if applicationOnly, ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval"].contains(method) {
                try write(["id": wireID, "result": ["decision": "decline"]])
                return
            }
            if method == "item/tool/requestUserInput" || method == "tool/requestUserInput" {
                var wire = params
                wire["wireID"] = wireID
                try presentQuestions(id: id, form: AgentQuestionParser.parse(params, claude: false), wire: wire)
                return
            }
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval"
                || method == "item/permissions/requestApproval" {
                try receiveCodexApproval(method: method, id: id, wireID: wireID, params: params)
            } else if method == "mcpServer/elicitation/request" {
                try receiveCodexElicitation(id: id, wireID: wireID, params: params)
            } else {
                try write(["id": wireID, "error": ["code": -32601, "message": "AgentKit does not support this interaction: \(method)"]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Codex interaction: \(method)")))
            }
            return
        }
        if method == "serverRequest/resolved", let requestID = params["requestId"] {
            let id = agentProviderRequestKey(requestID)
            if questions.removeValue(forKey: id) != nil || approvals.removeValue(forKey: id) != nil {
                settle(id, text: "Resolved elsewhere or cancelled by the provider", outcome: .resolvedElsewhere)
                onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
            }
        }
        observeCodexChildren(method: method, params: params)
        if method == "account/rateLimits/updated", let limits = params["rateLimits"] as? [String: Any] {
            observeCodexRateLimits(limits)
        }
        // Agents Codex starts run in threads of their own; their notifications must not
        // end or fill this conversation's turn.
        if message["id"] == nil, let thread = params["threadId"] as? String, let threadID, thread != threadID { return }
        if method == "thread/tokenUsage/updated", params["threadId"] as? String != threadID { return }
        if let incomingTurn = params["turnId"] as? String, let turnID, incomingTurn != turnID { return }
        if method == "turn/started" || method == "turn/completed" {
            if let incomingTurn = (params["turn"] as? [String: Any])?["id"] as? String,
               let turnID, incomingTurn != turnID { return }
            if method == "turn/completed", !busy { return }
        }
        codex.receive(message, source: source)
        if method == "turn/started", let turn = params["turn"] as? [String: Any] { turnID = turn["id"] as? String }
        if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed", !interruptRequested {
                let error = turn["error"] as? [String: Any]
                reportCodexUsageLimit(error)
                fail(error?["message"] as? String ?? "Codex turn failed.")
            } else { completeTurn() }
        }
        if method == "error", params["willRetry"] as? Bool == true {
            retryAttempts += 1
            let error = params["error"] as? [String: Any]
            onEvent(.activity(AgentChatActivity(kind: .retrying, attempt: retryAttempts,
                message: (error?["message"] as? String).flatMap(agentSubagentText))))
        } else if method != nil, method != "error", retryAttempts > 0 {
            // The provider got through.
            retryAttempts = 0
            onEvent(.activity(nil))
        }
        if method == "error", params["willRetry"] as? Bool != true, !interruptRequested {
            let error = params["error"] as? [String: Any]
            reportCodexUsageLimit(error)
            fail(error?["message"] as? String ?? "Codex reported an error.")
        }
    }

    private func completeTurn() {
        cancelApplicationTools()
        if provider == .claude, !unconsumedClaudeInputs.isEmpty {
            // Claude answers the remaining follow-ups in a turn of their own.
            claude.beginTurn()
            finishApprovals()
            onEvent(.status(.working))
            return
        }
        let deferred = deferredSends
        deferredSends.removeAll()
        providerInitiatedTurn = false
        busy = false
        interruptRequested = false
        turnID = nil
        finishApprovals()
        // A send that waited for this turn starts now, so its own turn follows without
        // an idle moment in which the queue could deliver something else.
        if let next = deferred.first {
            next(nil)
            for send in deferred.dropFirst() { send(nil) }
            return
        }
        onEvent(.status(.idle))
    }

    private func resolveDeferredSends(_ error: Error) {
        let deferred = deferredSends
        deferredSends.removeAll()
        providerInitiatedTurn = false
        for send in deferred { send(error) }
    }

    /// Claude's `rate_limit_event`: a warning near the limit, a stop at it, else nothing.
    static func rateLimitActivity(_ info: [String: Any]) -> AgentChatActivity? {
        let resets = (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        switch info["status"] as? String {
        case "allowed_warning":
            let used = (info["utilization"] as? NSNumber).map { "\(Int(($0.doubleValue * 100).rounded()))% of the usage limit used" }
            return AgentChatActivity(kind: .rateLimitWarning, resumesAt: resets, message: used)
        case "rejected":
            return AgentChatActivity(kind: .rateLimited, resumesAt: resets, message: "Usage limit reached")
        default: return nil
        }
    }

    /// A transcript note for agents that stopped with their provider process.
    static func stoppedAgents(_ count: Int, because reason: String) -> String {
        (count == 1 ? "Stopped 1 running agent" : "Stopped \(count) running agents") + " because " + reason + "."
    }

    private func finishApprovals() {
        for id in questions.keys { settle(id, text: "Question cancelled — response ended", outcome: .ended) }
        questions.removeAll()
        for id in approvals.keys { settle(id, text: "No longer pending", outcome: .ended) }
        approvals.removeAll()
    }

    private func resolvePending(_ error: Error) {
        let completions = Array(pending.values)
        pending.removeAll()
        for completion in completions { completion(.failure(error)) }
    }

    private func fail(_ message: String) {
        guard !failed, !closed else { return }
        failed = true
        cancelApplicationTools()
        busy = false
        resolveDeferredSends(AgentRuntimeError(message))
        process?.stop()
        finishApprovals()
        onEvent(.failure(message))
        onEvent(.status(.failed))
        resolvePending(AgentRuntimeError(message))
    }

    deinit { process?.stop() }
}

internal func agentRuntimeID(_ value: Any) -> String { (value as? String) ?? String(describing: value) }

internal func agentRuntimeJSON(_ value: Any?, originalJSON: String? = nil) -> String? {
    if let value, JSONSerialization.isValidJSONObject(value), let originalJSON { return originalJSON }
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return value as? String }
    return text
}

internal func agentRuntimeStructuredJSON(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return string
}


extension AgentRuntime {
    private func presentQuestions(id: String, form: AgentQuestionnaire, wire: [String: Any]) throws {
        guard questions.count < 12, questions.values.reduce(0, { $0 + $1.form.transcriptByteCount }) + form.transcriptByteCount <= 128 * 1024 else { throw AgentRuntimeError("Too many pending question forms.") }
        questions[id] = (form, wire)
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: "Questions for you", isComplete: false,
                                   questionnaire: form)))
        onEvent(.status(.waiting))
    }

    func answer(request id: String, answers: [String: [String]], cancelled: Bool) async throws {
        try await perform {
            guard let pending = self.questions[id] else {
                if self.answeredQuestions.contains(id) { return }
                throw AgentRuntimeError("This question is no longer pending.")
            }
            try pending.form.validate(answers: answers, cancelled: cancelled)
            if pending.wire["elicitation"] != nil {
                // A form answered without offered decisions: Submit accepts, Cancel cancels.
                try self.decideElicitation(id, pending: pending, decision: cancelled ? "cancel" : "accept", answers: answers)
                return
            }
            if self.provider == .claude {
                var response: [String: Any] = ["behavior": cancelled ? "deny" : "allow"]
                if cancelled { response["message"] = "The user cancelled the questions." }
                else {
                    var input = pending.wire["input"] as? [String: Any] ?? [:]
                    input["answers"] = answers.mapValues { $0.joined(separator: ", ") }
                    response["updatedInput"] = input
                }
                if let tool = pending.wire["tool_use_id"] { response["toolUseID"] = tool }
                try self.write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
            } else {
                let values: [String: Any] = cancelled ? [:] : answers.mapValues { ["answers": $0] }
                try self.write(["id": pending.wire["wireID"] ?? id, "result": ["answers": values]])
            }
            self.questions.removeValue(forKey: id)
            self.answeredQuestions.insert(id)
            if self.answeredQuestions.count > 512 { self.answeredQuestions = [id] }
            let summary = cancelled ? nil : pending.form.questions.map { question in
                question.title + ": " + (question.secret ? "[Private answer provided]" : (answers[question.id] ?? []).joined(separator: ", "))
            }.joined(separator: "\n")
            self.onEvent(.item(AgentChatItem(id: id, kind: .approval,
                text: cancelled ? "Questions cancelled" : "Answered \(pending.form.questions.count) question(s)", detail: summary)))
            self.onEvent(.status(self.approvals.isEmpty && self.questions.isEmpty ? (self.busy ? .working : .idle) : .waiting))
        }
    }
}

private struct ApplicationCall {
    var call: AgentToolCall
    var item: AgentChatItem
    var result: AgentToolResult?
    var context: AgentToolExecutionContext
    var replies: [(AgentToolResult) -> [String: Any]]
}

extension AgentRuntime {
    private func applicationMCPResponse(_ id: String, _ body: [String: Any]) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": body]]
    }

    private func receiveApplicationMCP(_ request: [String: Any], requestID: String) throws {
        guard request["server_name"] as? String == "agentkit" || request["server_name"] == nil else {
            try write(["type": "control_response", "response": ["subtype": "error", "request_id": requestID,
                       "error": "Unknown application tool server."]])
            return
        }
        let message = request["message"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else {
            try write(applicationMCPResponse(requestID, ["mcp_response": [:]])); return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let reply: ([String: Any]) -> [String: Any] = { [weak self] result in
            self?.applicationMCPResponse(requestID, ["mcp_response": ["jsonrpc": "2.0", "id": id, "result": result]]) ?? [:]
        }
        switch message["method"] as? String {
        case "initialize":
            try write(reply(["protocolVersion": params["protocolVersion"] ?? "2025-06-18", "capabilities": ["tools": [:]],
                             "serverInfo": ["name": "agentkit", "version": AgentKitVersion.current]]))
        case "tools/list":
            let definitions = applicationTools?.definitions.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema.foundationValue] as [String: Any]
            } ?? []
            try write(reply(["tools": definitions]))
        case "tools/call":
            let metadata = params["_meta"] as? [String: Any]
            let call = AgentToolCall(id: metadata?["claudecode/toolUseId"] as? String ?? agentRuntimeID(id),
                                    name: params["name"] as? String ?? "",
                                    arguments: try AgentJSONValue(foundation: params["arguments"] ?? [:]))
            runApplicationTool(call) { result in reply(Self.claudeApplicationResult(result)) }
        default:
            try write(applicationMCPResponse(requestID, ["mcp_response": ["jsonrpc": "2.0", "id": id,
                      "error": ["code": -32601, "message": "Method not found"]]]))
        }
    }

    private static func claudeApplicationResult(_ result: AgentToolResult) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": result.text]]
        content += result.images.map { ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType] }
        return ["content": content, "isError": result.isError]
    }

    private static func codexApplicationResult(_ result: AgentToolResult) -> [String: Any] {
        var content: [[String: Any]] = [["type": "inputText", "text": result.text]]
        content += result.images.map { ["type": "inputImage", "imageUrl": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())"] }
        return ["contentItems": content, "success": !result.isError]
    }

    private func runApplicationTool(_ call: AgentToolCall, reply: @escaping (AgentToolResult) -> [String: Any]) {
        do {
            guard let tools = applicationTools, tools.definitions.contains(where: { $0.name == call.name }) else {
                try write(reply(.failure("Unknown application tool: \(call.name)"))); return
            }
            guard busy, !interruptRequested, call.arguments.object != nil, !call.id.isEmpty, call.id.utf8.count <= 1024 else {
                try write(reply(.failure("The tool call was cancelled or its arguments are invalid."))); return
            }
            if var existing = applicationCalls[call.id] {
                guard existing.call == call else {
                    try write(reply(.failure("A tool call ID was reused with different arguments."))); return
                }
                if let result = existing.result { try write(reply(result)) }
                else { existing.replies.append(reply); applicationCalls[call.id] = existing }
                return
            }
            guard applicationTasks.count + applicationQueue.count < 64 else {
                try write(reply(.failure("Too many pending application tool calls."))); return
            }
            var item = AgentChatItem(id: call.id, kind: .tool, text: call.name, isComplete: false,
                                     tool: .init(name: call.name, category: .other, input: call.arguments.text,
                                                 status: .queued, presentation: .dynamicTool))
            item.tool?.isApplicationTool = true
            let context = AgentToolExecutionContext(callID: call.id, tool: call.name)
            applicationLeases[context.id] = context
            applicationCalls[call.id] = ApplicationCall(call: call, item: item, context: context, replies: [reply])
            applicationCallOrder.append(call.id)
            onEvent(.item(item))
            if tools.concurrentTools.contains(call.name) { startApplicationTool(call.id) }
            else { applicationQueue.append(call.id); drainApplicationTools() }
        } catch { fail(error.localizedDescription) }
    }

    private func drainApplicationTools() {
        guard !cancellingApplicationTools, busy, !interruptRequested, applicationSerialID == nil,
              !applicationQueue.isEmpty else { return }
        let id = applicationQueue.removeFirst()
        applicationSerialID = id
        startApplicationTool(id)
    }

    private func startApplicationTool(_ id: String) {
        guard let tools = applicationTools, var pending = applicationCalls[id], pending.result == nil else { return }
        let context = pending.context, call = pending.call, generation = processGeneration
        pending.item.tool?.status = .running
        pending.item.tool?.startedAt = Date()
        AgentLog.logger.info("application_tool_start call=\(id, privacy: .public) tool=\(call.name, privacy: .public) lease=\(context.id.uuidString, privacy: .public)")
        applicationCalls[id] = pending
        onEvent(.item(pending.item))
        applicationTasks[id] = Task { [weak self] in
            let result = await AgentToolExecutionContext.$current.withValue(context) {
                guard !context.isCancelled, !Task.isCancelled else { return AgentToolResult.failure("Tool call cancelled.") }
                return await tools.handle(call)
            }
            self?.queue.async { [weak self] in
                guard let self, !self.closed, !self.failed, self.processGeneration == generation,
                      self.applicationTasks[id] != nil, self.applicationCalls[id]?.context.id == context.id else { return }
                self.finishApplicationTool(id, result: result)
            }
        }
        // Do not race children in a task group: leaving its scope would wait for a
        // cancellation-uncooperative host. This timer retires the invocation directly.
        queue.asyncAfter(deadline: .now() + tools.executionTimeout) { [weak self] in
            guard let self, self.applicationTasks[id] != nil,
                  self.applicationCalls[id]?.context.id == context.id else { return }
            context.revoke()
            self.applicationTasks[id]?.cancel()
            self.finishApplicationTool(id, result: .failure("Tool timed out. Execution authority was revoked; inspect the application state before retrying."), timedOut: true)
        }
    }

    private func finishApplicationTool(_ id: String, result supplied: AgentToolResult, interrupted: Bool = false, timedOut: Bool = false) {
        guard var pending = applicationCalls[id], pending.result == nil else { return }
        var result = supplied
        do {
            try AgentChatAttachment.validate(result.images)
            guard result.images.allSatisfy({ ["image/jpeg", "image/png", "image/gif", "image/webp"].contains($0.mimeType) }) else {
                throw AgentRuntimeError("Unsupported tool image format.")
            }
        } catch {
            result.images = []
            result.text += "\nPresentation warning: " + error.localizedDescription
        }
        let fullText = result.text
        if result.text.utf8.count > 1024 * 1024 {
            var summary: [String: Any] = ["presentation_warning": "Result exceeds transport limit. Execution outcome is unchanged; full output is retained in the tool inspector.", "is_error": result.isError]
            if let original = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] {
                for key in ["revision", "draft_id", "operation_id", "mutation", "error"] {
                    if let value = original[key] as? String, value.utf8.count < 4096 { summary[key] = value }
                }
            }
            result.text = agentRuntimeJSON(summary) ?? "Execution finished; full output is retained in the tool inspector."
        }
        pending.result = result
        pending.item.isComplete = true
        pending.item.detail = result.text
        pending.item.tool?.output = fullText
        pending.item.tool?.status = interrupted ? .interrupted : timedOut ? .timedOut : result.isError ? .failed : .completed
        pending.item.tool?.completedAt = Date()
        AgentLog.logger.info("application_tool_finish call=\(id, privacy: .public) tool=\(pending.call.name, privacy: .public) status=\(pending.item.tool?.status?.rawValue ?? "unknown", privacy: .public)")
        pending.item.attachments = result.images.isEmpty ? nil : result.images.map(\.descriptor)
        let replies = pending.replies
        pending.replies.removeAll()
        applicationCalls[id] = pending
        applicationTasks.removeValue(forKey: id)
        if applicationSerialID == id { applicationSerialID = nil }
        onEvent(result.images.isEmpty ? .item(pending.item) : .toolItem(pending.item, images: result.images))
        if !closed, !failed {
            do { for reply in replies { try write(reply(result)) } }
            catch { fail(error.localizedDescription) }
        }
        drainApplicationTools()
        // Keep enough completed call IDs to deduplicate provider retries without growing forever.
        while applicationCallOrder.count > 512, let first = applicationCallOrder.first,
              applicationCalls[first]?.result != nil {
            applicationCallOrder.removeFirst(); applicationCalls.removeValue(forKey: first)
        }
    }

    private func cancelApplicationTools() {
        cancellingApplicationTools = true
        let leases = applicationLeases.values
        applicationLeases.removeAll()
        for context in leases { context.revoke() }
        let ids = Set(applicationTasks.keys).union(applicationQueue)
        applicationQueue.removeAll()
        applicationSerialID = nil
        for id in ids {
            applicationTasks[id]?.cancel()
            finishApplicationTool(id, result: .failure("Tool call cancelled; no further work is authorized."), interrupted: true)
        }
        cancellingApplicationTools = false
    }
}

/// A server request's key: its transcript item ID and the session's request name. Numbers
/// keep their decimal spelling, as before; a string that reads as a number, or as such an
/// escape, is prefixed, so request `7` and request `"7"` never share an item.
internal func agentProviderRequestKey(_ value: Any) -> String {
    if let text = value as? String {
        return Double(text) != nil || text.hasPrefix("str:") ? "str:" + text : text
    }
    return agentRuntimeID(value)
}

/// The request ID exactly as the provider sent it.
internal func agentProviderRequestValue(_ value: Any) -> AgentJSONValue? {
    if let text = value as? String { return .string(text) }
    if let number = value as? NSNumber { return .number(number.doubleValue) }
    return nil
}

// MARK: Provider requests with offered decisions

extension AgentRuntime {
    /// Codex's command, file-change and permission approvals: the provider's own decisions,
    /// what is asked for, and who asked.
    fileprivate func receiveCodexApproval(method: String, id: String, wireID: Any, params: [String: Any]) throws {
        var approval = params
        approval["wireID"] = wireID
        approval["method"] = method
        let permissions = method == "item/permissions/requestApproval"
        let (decisions, values) = permissions ? Self.permissionDecisions() : Self.codexDecisions(method: method, params: params)
        guard !decisions.isEmpty else {
            try write(["id": wireID, "error": ["code": -32602, "message": "AgentKit can't show any of the decisions offered for this request."]])
            onEvent(.item(AgentChatItem(kind: .notice, text: "Codex asked for an approval with no decision AgentKit can show, so it was refused.")))
            return
        }
        approval["decisionValues"] = values
        var requested: [String] = []
        let summary: String
        let scope: String?
        switch method {
        case "item/permissions/requestApproval":
            requested = Self.describe(permissions: params["permissions"] as? [String: Any] ?? [:])
            summary = params["reason"] as? String ?? "Allow additional permissions"
            scope = (params["cwd"] as? String).map { "Working in " + $0 }
        case "item/fileChange/requestApproval":
            summary = params["reason"] as? String ?? "Approve file changes"
            scope = (params["grantRoot"] as? String).map { "Writes under " + $0 }
        default:
            summary = params["command"] as? String ?? params["reason"] as? String ?? "Run a command"
            scope = (params["cwd"] as? String).map { "Runs in " + $0 }
            if let reason = params["reason"] as? String, params["command"] != nil { requested.append(reason) }
            if let host = (params["networkApprovalContext"] as? [String: Any])?["host"] as? String { requested.append("Network access to " + host) }
        }
        let interaction = AgentApprovalRequest(method: method, providerRequestID: agentProviderRequestValue(wireID), summary: summary,
            scope: scope, requested: requested.isEmpty ? nil : Array(requested.prefix(64)), decisions: decisions, origin: origin(params))
        approvals[id] = approval
        interactions[id] = interaction
        if automaticallyAllows(approval), let allow = interaction.only(.allowOnce) {
            try writeCodexDecision(id, approval: approval, decision: allow.id)
            finishDecision(id, approval: approval, decision: allow, automatic: true)
            return
        }
        let kind = method == "item/fileChange/requestApproval" ? "file-change" : permissions ? "permissions" : "command"
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: summary, detail: agentRuntimeJSON(params), isComplete: false,
                                   workContext: .init(providerTurnID: params["turnId"] as? String, requestKind: kind),
                                   interaction: interaction)))
        onEvent(.status(.waiting))
    }

    /// The decisions Codex offers for a command or file change: `availableDecisions` in its
    /// order when sent, else the four its schema defines. Unknown ones are left out.
    static func codexDecisions(method: String, params: [String: Any]) -> ([AgentApprovalDecision], [String: Any]) {
        let offered: [Any] = params["availableDecisions"] as? [Any] ?? ["accept", "acceptForSession", "decline", "cancel"]
        let command = method == "item/commandExecution/requestApproval"
        var decisions: [AgentApprovalDecision] = [], values: [String: Any] = [:]
        for value in offered {
            let decision: AgentApprovalDecision?
            if let token = value as? String {
                switch token {
                case "accept": decision = .init(id: token, kind: .allowOnce, label: "Allow once",
                    consequence: command ? "Runs this command only." : "Applies these changes only.")
                case "acceptForSession": decision = .init(id: token, kind: .allowSession, label: "Allow for session",
                    consequence: command ? "Runs it, and matching commands without asking until Codex restarts." : "Applies them, and later changes to the same files without asking until Codex restarts.")
                case "decline": decision = .init(id: token, kind: .decline, label: "Decline", consequence: "Refuses it; the agent carries on without it.")
                case "cancel": decision = .init(id: token, kind: .cancel, label: "Decline and stop", consequence: "Refuses it and stops the turn.")
                default: decision = nil
                }
            } else if let object = value as? [String: Any], object.count == 1, let key = object.keys.first {
                let body = object[key] as? [String: Any] ?? [:]
                switch key {
                case "acceptWithExecpolicyAmendment":
                    let prefix = (body["execpolicy_amendment"] as? [String])?.joined(separator: " ") ?? ""
                    decision = .init(id: key, kind: .allowAlways, label: prefix.isEmpty ? "Always allow" : "Always allow “\(prefix.prefix(60))”",
                                     consequence: "Runs it, and adds a rule so commands starting with it run without asking.")
                case "applyNetworkPolicyAmendment":
                    let amendment = body["network_policy_amendment"] as? [String: Any] ?? [:]
                    let host = amendment["host"] as? String ?? "this host"
                    let allow = amendment["action"] as? String == "allow"
                    decision = .init(id: key, kind: allow ? .allowAlways : .decline,
                                     label: (allow ? "Always allow " : "Always block ") + String(host.prefix(60)),
                                     consequence: allow ? "Adds a rule allowing connections to \(host)." : "Adds a rule refusing connections to \(host).")
                default: decision = nil
                }
            } else { decision = nil }
            guard let decision, values[decision.id] == nil else { continue }
            decisions.append(decision)
            values[decision.id] = value
        }
        return (decisions, values)
    }

    /// A permission grant reaches this turn or the whole session; declining grants nothing.
    static func permissionDecisions() -> ([AgentApprovalDecision], [String: Any]) {
        ([.init(id: "turn", kind: .allowOnce, label: "Allow for this turn", consequence: "Grants the permissions until this turn ends."),
          .init(id: "session", kind: .allowSession, label: "Allow for session", consequence: "Grants the permissions until Codex restarts."),
          .init(id: "decline", kind: .decline, label: "Decline", consequence: "Grants nothing; the agent carries on without them.")],
         ["turn": "turn", "session": "session", "decline": "decline"])
    }

    /// The requested permission profile, a line per path or capability.
    static func describe(permissions: [String: Any]) -> [String] {
        var lines: [String] = []
        let files = permissions["fileSystem"] as? [String: Any] ?? [:]
        for path in files["read"] as? [String] ?? [] { lines.append("Read " + path) }
        for path in files["write"] as? [String] ?? [] { lines.append("Write " + path) }
        for entry in files["entries"] as? [[String: Any]] ?? [] {
            let access = (entry["access"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Access"
            let path = entry["path"] as? [String: Any] ?? [:]
            let target = path["path"] as? String ?? path["pattern"] as? String
                ?? ((path["value"] as? [String: Any])?["kind"] as? String).map { "special: " + $0 } ?? "a path"
            lines.append(access + " " + target)
        }
        if let network = permissions["network"] as? [String: Any], network["enabled"] as? Bool == true { lines.append("Network access") }
        return lines.isEmpty ? ["No specific access listed"] : lines
    }

    /// Who asked: a child agent's thread, named by the row that started it.
    fileprivate func origin(_ params: [String: Any]) -> AgentRequestOrigin? {
        guard let thread = params["threadId"] as? String, let threadID, thread != threadID else { return nil }
        return AgentRequestOrigin(threadID: thread, agentID: thread, toolUseID: childThreads[thread])
    }

    fileprivate func claudeInteraction(id: String, tool: String, origin: AgentRequestOrigin) -> AgentApprovalRequest {
        var decisions: [AgentApprovalDecision] = [.init(id: "allow", kind: .allowOnce, label: "Allow")]
        if AgentApprovalScope.canAlwaysAllow(tool) {
            decisions.append(.init(id: "allowAlways", kind: .allowSession, label: "Always Allow",
                                   consequence: "Lets \(tool) run without asking for the rest of this conversation."))
        }
        decisions.append(.init(id: "deny", kind: .decline, label: "Deny"))
        return AgentApprovalRequest(method: "can_use_tool", providerRequestID: .string(id), summary: tool, decisions: decisions, origin: origin)
    }

    /// An MCP server's elicitation: a form of primitive fields becomes the native question
    /// card, an empty form an approval; anything else is refused explicitly.
    fileprivate func receiveCodexElicitation(id: String, wireID: Any, params: [String: Any]) throws {
        let server = params["serverName"] as? String ?? "An MCP server"
        let message = params["message"] as? String ?? "\(server) asks for input"
        let parsed: Result<(AgentQuestionnaire?, [String: [String: Any]]), AgentRuntimeError>
        if params["mode"] as? String == "form", let schema = params["requestedSchema"] as? [String: Any] {
            parsed = Self.elicitationForm(schema)
        } else {
            parsed = .failure(AgentRuntimeError("its \(params["mode"] as? String ?? "unknown") mode isn't supported"))
        }
        switch parsed {
        case .failure(let reason):
            try write(["id": wireID, "error": ["code": -32602, "message": "AgentKit can't show this MCP request: \(reason.message)."]])
            onEvent(.item(AgentChatItem(kind: .notice, text: "\(server) asked for input AgentKit can't show (\(reason.message)), so the request was refused.")))
        case .success(let (form, fields)):
            var wire = params
            wire["wireID"] = wireID
            wire["elicitation"] = true
            wire["fields"] = fields
            let decisions: [AgentApprovalDecision] = [
                .init(id: "accept", kind: form == nil ? .allowOnce : .submit, label: form == nil ? "Allow" : "Submit",
                      consequence: form == nil ? "Tells \(server) to go ahead." : "Sends your answers to \(server)."),
                .init(id: "decline", kind: .decline, label: "Decline", consequence: "Tells \(server) you declined."),
                .init(id: "cancel", kind: .cancel, label: "Cancel", consequence: "Dismisses the request without an answer.")]
            let interaction = AgentApprovalRequest(method: "mcpServer/elicitation/request", providerRequestID: agentProviderRequestValue(wireID),
                summary: message, scope: "MCP server " + server, decisions: decisions, origin: origin(params))
            interactions[id] = interaction
            if let form {
                guard questions.count < 12 else { throw AgentRuntimeError("Too many pending question forms.") }
                questions[id] = (form, wire)
            } else {
                approvals[id] = wire
            }
            onEvent(.item(AgentChatItem(id: id, kind: .approval, text: message, isComplete: false,
                                       workContext: .init(providerTurnID: params["turnId"] as? String, requestKind: "elicitation"),
                                       questionnaire: form, interaction: interaction)))
            onEvent(.status(.waiting))
        }
    }

    /// The form's questions and, per field, how an answer becomes its typed value.
    static func elicitationForm(_ schema: [String: Any]) -> Result<(AgentQuestionnaire?, [String: [String: Any]]), AgentRuntimeError> {
        guard schema["type"] as? String == "object", let properties = schema["properties"] as? [String: Any] else {
            return .failure(AgentRuntimeError("its form isn't an object schema"))
        }
        guard !properties.isEmpty else { return .success((nil, [:])) }
        guard properties.count <= 12 else { return .failure(AgentRuntimeError("it has more than 12 fields")) }
        let required = Set(schema["required"] as? [String] ?? [])
        var questions: [AgentQuestionnaire.Question] = [], fields: [String: [String: Any]] = [:]
        for name in properties.keys.sorted() {
            guard let field = properties[name] as? [String: Any], let type = field["type"] as? String else {
                return .failure(AgentRuntimeError("field \(name) has no type"))
            }
            var title = field["title"] as? String ?? name
            if let description = field["description"] as? String, !description.isEmpty { title += " — " + description }
            var options: [(label: String, value: String)] = []
            var multiple = false
            switch type {
            case "string":
                if let values = field["enum"] as? [String] {
                    let names = field["enumNames"] as? [String]
                    options = values.enumerated().map { (names?.indices.contains($0.offset) == true ? names?[$0.offset] ?? $0.element : $0.element, $0.element) }
                } else if let choices = field["oneOf"] as? [[String: Any]] {
                    options = choices.compactMap { choice in (choice["const"] as? String).map { (choice["title"] as? String ?? $0, $0) } }
                }
            case "array":
                multiple = true
                let items = field["items"] as? [String: Any] ?? [:]
                if let values = items["enum"] as? [String] { options = values.map { ($0, $0) } }
                else if let choices = items["anyOf"] as? [[String: Any]] {
                    options = choices.compactMap { choice in (choice["const"] as? String).map { (choice["title"] as? String ?? $0, $0) } }
                }
                guard !options.isEmpty else { return .failure(AgentRuntimeError("list field \(name) offers no choices")) }
            case "boolean": options = [("Yes", "true"), ("No", "false")]
            case "number", "integer": break
            default: return .failure(AgentRuntimeError("field \(name) has unsupported type \(type)"))
            }
            guard Set(options.map(\.label)).count == options.count else { return .failure(AgentRuntimeError("field \(name) repeats a choice")) }
            questions.append(.init(id: name, title: title, options: options.map { .init(label: $0.label) }, multiple: multiple,
                                   required: required.contains(name)))
            fields[name] = ["type": type, "choices": Dictionary(options.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first }),
                            "closed": !options.isEmpty]
        }
        let form = AgentQuestionnaire(questions: questions)
        do { try form.validate() } catch { return .failure(AgentRuntimeError("its form is too large")) }
        return .success((form, fields))
    }

    /// Answers a request with one of its offered decisions.
    func decide(request id: String, decision: String, answers: [String: [String]]?) async throws {
        try await perform {
            if self.decided[id] == decision { return }
            if let pending = self.questions[id] {
                guard pending.wire["elicitation"] != nil else { throw AgentRuntimeError("Answer this form with its questions.") }
                try self.decideElicitation(id, pending: pending, decision: decision, answers: answers ?? [:])
                return
            }
            guard let approval = self.approvals[id], let interaction = self.interactions[id],
                  let chosen = interaction.decision(decision) else {
                throw AgentRuntimeError(self.decided[id] != nil ? "This request was already answered." : "This request is no longer pending.")
            }
            if self.provider == .claude {
                if decision == "allowAlways", let tool = approval["tool_name"] as? String {
                    self.alwaysAllowedTools.insert(tool)
                }
                try self.resolveClaude(id, approval: approval, allow: chosen.kind.allows)
            } else {
                try self.writeCodexDecision(id, approval: approval, decision: decision)
            }
            self.finishDecision(id, approval: approval, decision: chosen, automatic: false)
            if self.provider == .claude, decision == "allowAlways" { try self.allowPendingAutomatically() }
        }
    }

    private func resolveClaude(_ id: String, approval: [String: Any], allow: Bool) throws {
        var response: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow { response["updatedInput"] = approval["input"] as? [String: Any] ?? [:] }
        else { response["message"] = "User declined tool execution." }
        if let toolID = approval["tool_use_id"] { response["toolUseID"] = toolID }
        try write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    fileprivate func decideElicitation(_ id: String, pending: (form: AgentQuestionnaire, wire: [String: Any]), decision: String,
                                       answers: [String: [String]]) throws {
        guard ["accept", "decline", "cancel"].contains(decision) else { throw AgentRuntimeError("The MCP server didn't offer that answer.") }
        var result: [String: Any] = ["action": decision]
        if decision == "accept" {
            try pending.form.validate(answers: answers, cancelled: false)
            let fields = pending.wire["fields"] as? [String: [String: Any]] ?? [:]
            var content: [String: Any] = [:]
            for question in pending.form.questions {
                guard let values = answers[question.id], !values.isEmpty, let field = fields[question.id] else { continue }
                content[question.id] = try Self.typed(values, field: field, title: question.title)
            }
            result["content"] = content
        } else { result["content"] = NSNull() }
        try write(["id": pending.wire["wireID"] ?? id, "result": result])
        questions.removeValue(forKey: id)
        answeredQuestions.insert(id)
        var interaction = interactions.removeValue(forKey: id)
        interaction?.chosen = decision
        interaction?.outcome = .decided
        decided[id] = decision
        let summary = decision != "accept" ? nil : pending.form.questions.map { question in
            question.title + ": " + (answers[question.id] ?? []).joined(separator: ", ")
        }.joined(separator: "\n")
        let label = interaction?.decision(decision)?.label ?? decision
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: decision == "accept" ? "Submitted" : label == "Cancel" ? "Cancelled" : "Declined",
                                   detail: summary, interaction: interaction)))
        onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    /// An answer as the field's schema type: a number, a boolean, a choice's value or a list.
    static func typed(_ values: [String], field: [String: Any], title: String) throws -> Any {
        let choices = field["choices"] as? [String: String] ?? [:]
        let closed = field["closed"] as? Bool == true
        let mapped = try values.map { value -> String in
            if let choice = choices[value] { return choice }
            guard !closed else { throw AgentRuntimeError("Choose one of the offered answers for “\(title)”.") }
            return value
        }
        switch field["type"] as? String {
        case "array": return mapped
        case "boolean": return mapped.first == "true"
        case "integer":
            guard let first = mapped.first, let number = Int(first.trimmingCharacters(in: .whitespaces)) else {
                throw AgentRuntimeError("“\(title)” needs a whole number.")
            }
            return number
        case "number":
            guard let first = mapped.first, let number = Double(first.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                throw AgentRuntimeError("“\(title)” needs a number.")
            }
            return number
        default: return mapped.first ?? ""
        }
    }

    fileprivate func writeCodexDecision(_ id: String, approval: [String: Any], decision: String) throws {
        let wireID = approval["wireID"] ?? id
        if approval["elicitation"] != nil {
            guard ["accept", "decline", "cancel"].contains(decision) else { throw AgentRuntimeError("The MCP server didn't offer that answer.") }
            try write(["id": wireID, "result": ["action": decision, "content": decision == "accept" ? [String: Any]() as Any : NSNull() as Any]])
            return
        }
        let values = approval["decisionValues"] as? [String: Any] ?? [:]
        guard let value = values[decision] else { throw AgentRuntimeError("Codex didn't offer that decision.") }
        if approval["method"] as? String == "item/permissions/requestApproval" {
            let granted: Any = decision == "decline" ? [String: Any]() : approval["permissions"] ?? [String: Any]()
            try write(["id": wireID, "result": ["permissions": granted, "scope": decision == "session" ? "session" : "turn"]])
        } else {
            try write(["id": wireID, "result": ["decision": value]])
        }
    }

    /// Records a decision sent, on the card and in its history.
    fileprivate func finishDecision(_ id: String, approval: [String: Any], decision: AgentApprovalDecision, automatic: Bool) {
        approvals.removeValue(forKey: id)
        decided[id] = decision.id
        if decided.count > 512 { decided = [id: decision.id] }
        if id.utf8.count <= 1024, completedApprovals.insert(id).inserted {
            completedApprovalOrder.append(id)
            if completedApprovalOrder.count > 512 { completedApprovals.remove(completedApprovalOrder.removeFirst()) }
        }
        var interaction = interactions.removeValue(forKey: id)
        interaction?.chosen = decision.id
        interaction?.outcome = automatic ? .automatic : .decided
        let text = automatic ? "Automatically approved" : Self.recorded(decision)
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: text, interaction: interaction)))
        onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    /// The history's words for a decision sent, matching its kind.
    static func recorded(_ decision: AgentApprovalDecision) -> String {
        switch decision.kind {
        case .allowOnce: "Approved"
        case .allowSession: "Approved for the session"
        case .allowAlways: "Approved: " + decision.label
        case .decline: decision.id == "decline" || decision.id == "deny" ? "Declined" : "Declined: " + decision.label
        case .cancel: "Declined and stopped"
        case .submit: "Submitted"
        default: decision.label
        }
    }

    /// Ends a pending request nobody answered, keeping its card with how it ended.
    fileprivate func settle(_ id: String, text: String, outcome: AgentApprovalRequest.Outcome) {
        var interaction = interactions.removeValue(forKey: id)
        interaction?.outcome = outcome
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: text, interaction: interaction)))
    }

    /// Follows Codex's child agents: which row started each thread, and when one ends, its
    /// unanswered requests expire, since nothing is waiting for their answer.
    fileprivate func observeCodexChildren(method: String?, params: [String: Any]) {
        if method == "item/started" || method == "item/completed",
           let item = params["item"] as? [String: Any], item["type"] as? String == "collabAgentToolCall", let row = item["id"] as? String {
            for thread in item["receiverThreadIds"] as? [String] ?? [] where childThreads[thread] == nil || childThreads.count < 256 {
                childThreads[thread] = childThreads[thread] ?? row
            }
            for (thread, state) in item["agentsStates"] as? [String: [String: Any]] ?? [:]
                where ["completed", "errored", "shutdown", "interrupted", "notFound"].contains(state["status"] as? String ?? "") {
                expireRequests(from: thread)
            }
        }
        if method == "thread/closed", let thread = params["threadId"] as? String, thread != threadID { expireRequests(from: thread) }
    }

    fileprivate func expireRequests(from thread: String) {
        let expired = interactions.filter { $0.value.origin?.threadID == thread }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired {
            approvals.removeValue(forKey: id)
            questions.removeValue(forKey: id)
            settle(id, text: "Expired: the agent that asked has ended", outcome: .expired)
        }
        onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    /// Codex's rolling limits: a reached limit is shown with the latest reset it names.
    fileprivate func observeCodexRateLimits(_ limits: [String: Any]) {
        let resets = ["primary", "secondary"].compactMap { (limits[$0] as? [String: Any])?["resetsAt"] as? NSNumber }
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        if let latest = resets.max() { codexRateLimitReset = latest }
        guard let reached = limits["rateLimitReachedType"] as? String else { return }
        onEvent(.activity(AgentChatActivity(kind: .rateLimited, resumesAt: resets.max(),
            message: reached == "rate_limit_reached" ? "Usage limit reached" : reached.replacingOccurrences(of: "_", with: " ").capitalized)))
    }

    /// A turn Codex ends at a usage limit is marked so before it fails.
    fileprivate func reportCodexUsageLimit(_ error: [String: Any]?) {
        guard let info = error?["codexErrorInfo"] as? String, info == "usageLimitExceeded" || info == "rateLimitExceeded" else { return }
        onEvent(.activity(AgentChatActivity(kind: .rateLimited, resumesAt: codexRateLimitReset,
                                            message: error?["message"] as? String ?? "Usage limit reached")))
    }
}
