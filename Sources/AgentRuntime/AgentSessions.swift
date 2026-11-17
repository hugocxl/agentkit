import AgentCore
import Foundation
import CryptoKit
import os

/// Injectable boundary: tests never need a provider executable.
protocol AgentSessionRuntime: Sendable {
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws
    func answer(request: String, answers: [String: [String]], cancelled: Bool) async throws
    func approve(request: String, allow: Bool) async throws
    /// Answers an approval, with `always` letting the same tool run unasked from now on
    /// and `reason` telling the agent why it was denied.
    func approve(request: String, allow: Bool, always: Bool, reason: String?) async throws
    /// The tools this conversation lets run without asking, held with its access mode.
    func setAlwaysAllowed(_ tools: Set<String>) async throws
    func setPlan(_ enabled: Bool) async throws
    func setAccess(_ mode: AgentAccessMode) async throws
    func interrupt() async throws
    func stop()
    /// Stops, then waits until the provider process has exited, for a host about to exit.
    func terminate()
    /// Called once, before the first message: what the provider process starts with.
    func prepare(_ launch: AgentLaunch)
    /// Whether a provider process of it may change files `scope` restores: one launching or
    /// running, stopping or not, in its folder, one inside it or one around it, as the
    /// folders were at its launch, or one found working there now.
    func mayRun(in scope: AgentRevertScope) -> Bool
    /// Whether a provider process of it that may change files `scope` restores was asked to
    /// stop and still runs.
    func isStopping(in scope: AgentRevertScope) -> Bool
    /// Its provider processes that may still run, for a revert to find where they work now.
    func providerProcesses() -> [Int32]
    /// Launches no provider process from now on: it is being retired.
    func refuseLaunches()
    /// Steers the turn with a follow-up, unless Stop cancels `delivery` before the provider
    /// takes it.
    func steer(text: String, attachments: [StagedAgentAttachment], delivery: AgentDelivery) async throws
}

/// A follow-up's hand-over to its provider, which Stop can cancel until the provider takes it.
final class AgentDelivery: @unchecked Sendable {
    private enum State { case pending, handedOver, cancelled }
    private let lock = NSLock()
    private var state = State.pending

    /// Hands the follow-up over unless Stop came first: true when it is the provider's now.
    func handOver() -> Bool {
        lock.withLock {
            if state == .pending { state = .handedOver }
            return state == .handedOver
        }
    }

    /// Stops the follow-up unless the provider took it already: true when it never will.
    @discardableResult
    func cancel() -> Bool {
        lock.withLock {
            if state == .pending { state = .cancelled }
            return state == .cancelled
        }
    }
}

/// What a conversation's provider process starts with beyond its arguments.
struct AgentLaunch: Sendable, Equatable {
    /// Added to the provider's environment, such as `TAB_AGENT_ID`.
    var environment: [String: String] = [:]
    /// Searched first on `PATH`, so the agent finds this Tab's `tab`.
    var path: String?
    /// The provider conversation to fork rather than resume, until the provider
    /// names the new one.
    var forkSource: String?
    /// The message of `forkSource` to fork at, rather than its latest.
    var forkPoint: String?
    /// Added to the provider's system prompt: where in Tab the agent runs.
    var instructions: String?
}

extension AgentSessionRuntime {
    func answer(request: String, answers: [String: [String]], cancelled: Bool) async throws {
        throw AgentRuntimeError("This runtime does not support question forms.")
    }
    func setPlan(_ enabled: Bool) async throws {
        if enabled { throw AgentRuntimeError("This runtime does not support plan mode.") }
    }

    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        throw AgentRuntimeError("This runtime does not support messages during an active response.")
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        guard attachments.isEmpty else { throw AgentRuntimeError("This agent runtime does not support attachments.") }
        try await send(text: text, model: model, reasoningEffort: reasoningEffort)
    }

    func prepare(_ launch: AgentLaunch) {}

    func terminate() { stop() }

    func mayRun(in scope: AgentRevertScope) -> Bool { false }
    func isStopping(in scope: AgentRevertScope) -> Bool { false }
    func providerProcesses() -> [Int32] { [] }
    func refuseLaunches() {}

    func steer(text: String, attachments: [StagedAgentAttachment], delivery: AgentDelivery) async throws {
        guard delivery.handOver() else { throw AgentFollowUpRefused() }
        try await steer(text: text, attachments: attachments)
    }

    func approve(request: String, allow: Bool, always: Bool, reason: String?) async throws {
        guard !always, reason == nil else { throw AgentRuntimeError("This agent can only answer an approval once.") }
        try await approve(request: request, allow: allow)
    }

    func setAlwaysAllowed(_ tools: Set<String>) async throws {}
}

extension AgentRuntime: AgentSessionRuntime {}

/// Conversation ownership is independent of sockets, terminal channels and app references.
final class AgentSessions: @unchecked Sendable {
    typealias Factory = @Sendable (AgentChatProvider, String, String?,
                                  @escaping @Sendable (AgentRuntimeEvent) -> Void) -> any AgentSessionRuntime
    /// All mutable fields are confined to `queue`, including completion callbacks.
    private final class Entry: @unchecked Sendable {
        var resetting = false
        var archived = false
        var inbox = AgentPromptInbox()
        var inboxError: String?
        var deliveryCancelled = false
        var deliveryID: String?
        var snapshot: AgentChatSnapshot
        let directory: String
        var runtime: (any AgentSessionRuntime)?
        var generation = UUID()
        var submitting = false
        /// The submission in flight is a follow-up to the running turn, not its start.
        var steering = false
        var pendingSubmission: PendingReply?
        var approving: Set<String> = []
        var interrupting: UUID?
        var notifying = false
        var checkpointing = false
        var hasSuccessfulTurn = false
        var accessTask: Task<Void, Error>?
        /// The current turn's checkpoint baseline, once one is being taken.
        var baseline: CheckpointBaseline?
        /// Takes this conversation's checkpoints, and applies its reverts, in the order asked.
        let checkpoints = DispatchQueue(label: "agent.checkpoints", qos: .utility)
        /// Reverts admitted and not yet recorded: the conversation can't be cleared meanwhile.
        var reverts = 0
        var stagingToolImages = false
        var deferredEvents: [AgentRuntimeEvent] = []
        var deferredEventBytes = 0
        var deferredEventOverflow = false
        /// The provider conversation this one forks, until the provider names its own.
        var forkSource: String?
        /// The message of `forkSource` the fork ends at, so it leaves out what the
        /// source said after the fork was made.
        var forkPoint: String?
        /// The latest message the provider wrote to this conversation.
        var lastProviderMessage: String?
        /// Each agent's own steps, by the tool call that started it; held with the provider process.
        var subagentSteps: [String: [AgentChatItem]] = [:]
        /// Where each turn began in the provider's conversation, by its user item, so a
        /// fork can start from before it.
        var turnForkPoints: [String: ForkPoint] = [:]
        /// Tools the user allowed for the rest of this conversation. Choosing Ask clears them.
        var alwaysAllowedTools: Set<String> = []
        /// The revision at which each item last changed, for incremental reads, and the
        /// items as of the last revision to find what changed. Memory only: after a restart
        /// every item counts as changed at the loaded revision.
        var itemRevisions: [String: UInt64] = [:]
        var observedItems: [String: AgentChatItem] = [:]

        init(_ snapshot: AgentChatSnapshot, directory: String) {
            self.snapshot = snapshot
            self.directory = directory
            hasSuccessfulTurn = snapshot.items.contains { $0.kind == .assistant || $0.kind == .tool }
                || (snapshot.status == .idle && snapshot.items.contains { $0.kind == .user })
        }
    }

    /// A provider conversation and the message in it a fork resumes at.
    struct ForkPoint: Codable, Equatable {
        var session: String
        var message: String
    }

    private struct Saved: Codable {
        var turnForkPoints: [String: ForkPoint]?
        var alwaysAllowedTools: [String]?
        var snapshot: AgentChatSnapshot
        var directory: String
        var hasSuccessfulTurn: Bool?
        var forkSource: String?
        var forkPoint: String?
        var lastProviderMessage: String?
        var archived: Bool?
    }

    /// Where a request's snapshot goes: a waiting caller, or a queued delivery that
    /// must begin on `queue` before the reply to the submit that started it.
    private struct Reply: Sendable {
        let complete: @Sendable (Result<AgentChatSnapshot, Error>) -> Void

        init(_ complete: @escaping @Sendable (Result<AgentChatSnapshot, Error>) -> Void) { self.complete = complete }
        init(_ continuation: CheckedContinuation<AgentChatSnapshot, Error>) {
            complete = { continuation.resume(with: $0) }
        }

        func resume(returning snapshot: AgentChatSnapshot) { complete(.success(snapshot)) }
        func resume(throwing error: Error) { complete(.failure(error)) }
    }

    private final class PendingReply: @unchecked Sendable {
        var finished = false // Confined to queue.
        /// A follow-up the user stopped. Confined to queue.
        var stopped = false
        let continuation: Reply
        var task: Task<Void, Never>?
        /// A follow-up's hand-over to its provider; `nil` for other requests.
        let delivery: AgentDelivery?

        init(_ continuation: Reply, delivery: AgentDelivery? = nil) {
            self.continuation = continuation
            self.delivery = delivery
        }
    }

    private let queue = DispatchQueue(label: "tab.agents.sessions", qos: .userInitiated)
    /// Writes records and removes files, in the order asked.
    private let writer: DispatchQueue
    /// Closed once the store is released to its next owner: nothing is written after.
    private let fence = AgentStoreFence()
    /// Takes and removes checkpoints.
    private let checkpointStore: AgentCheckpointStore
    /// Checkpoints being taken and reverts being applied. Each changes refs, files and
    /// records the store's next owner must find whole, so shutdown waits for them.
    private let storeWork = DispatchGroup()
    /// How long shutdown waits for them; `nil`, the default, waits until they end, which
    /// Git's own time limits bound. With a limit, the store stays held until they end.
    var checkpointDrain: TimeInterval?
    private var retainedCheckpointIDs: [SessionId: Set<String>] = [:] // writer queue only
    private let root: URL
    private let factory: Factory
    private let projectDirectory: @Sendable (ProjectId) throws -> String
    private let submissionTimeout: TimeInterval
    private let interruptTimeout: TimeInterval
    /// Reports a chat's state with the folder it runs in.
    var activityChanged: @Sendable (AgentChatSnapshot, String) -> Void = { _, _ in }
    var changed: @Sendable (SessionId, UInt64) -> Void
    var checkDirectory: @Sendable (String) throws -> Void = { _ in }
    /// Host-supplied launch context; fork identity remains owned by the session store.
    var applicationToolSignature: String?
    var capturesCheckpoints = true
    var defaultAccess: AgentAccessMode = .fullAccess
    var launchContext: @Sendable (SessionId, ProjectId) -> AgentLaunch = { _, _ in AgentLaunch() }
    var stageToolImages: @Sendable ([AgentChatAttachment], URL) throws -> Void = { images, directory in
        let staged = try AgentAttachments.stageToolImages(images, root: directory)
        try AgentAttachments.record(staged, root: directory)
    }
    private var entries: [SessionId: Entry] = [:]
    /// Conversations a history import is being made into.
    private var importing: Set<SessionId> = []
    /// One folder's identity however its path is spelled, as through a symbolic link, so
    /// what is kept by folder meets; its resolved path when it can't be read.
    static func folderKey(_ path: String) -> String {
        var status = stat()
        if stat(path, &status) == 0 { return "\(status.st_dev):\(status.st_ino)" }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Steps tests follow a clear through.
    enum ClearStep: Sendable { case waiting, waited }
    /// Tests follow a clear here: as it starts waiting for the conversation's checkpoints,
    /// and once that wait is over.
    var clearStep: (@Sendable (ClearStep) async -> Void)?
    /// Whether providers started outside conversations, as for discovery, may change files a
    /// revert restores; the host's service answers for its own.
    var otherProvidersMayRun: @Sendable (AgentRevertScope) -> Bool = { _ in false }
    /// The processes of providers started outside conversations that may still run.
    var otherProviderProcesses: @Sendable () -> [Int32] = { [] }
    /// Tests hold a revert here, on the sessions queue, once admitted and before it is queued.
    var revertAdmitted: (@Sendable () -> Void)?
    /// Tests learn here, on the sessions queue, that a follow-up was admitted.
    var followUpAdmitted: (@Sendable () -> Void)?
    /// Whether the caller runs on the sessions queue, for tests checking where work runs.
    var onSessionsQueue: Bool { DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) }
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    /// The host's callbacks run here, in order and off the sessions queue, so one may call
    /// back into the conversations, even to shut them down.
    private let callbacks = DispatchQueue(label: "agentkit.sessions.callbacks")
    private static let callbackKey = DispatchSpecificKey<ObjectIdentifier>()
    var composerCatalog: (@Sendable (AgentComposerContextRequest) async throws -> AgentComposerContextReply)?
    private var stopping = false

    init(root: URL, projectDirectory: @escaping @Sendable (ProjectId) throws -> String,
         changed: @escaping @Sendable (SessionId, UInt64) -> Void = { _, _ in },
         submissionTimeout: TimeInterval = 120,
         interruptTimeout: TimeInterval = 15,
         closedRetention: TimeInterval = AgentSessions.closedRetention,
         writer: DispatchQueue = DispatchQueue(label: "tab.agents.persistence", qos: .utility),
         checkpoints: AgentCheckpointStore = AgentCheckpointStore(),
         factory: @escaping Factory = { provider, directory, resume, callback in
             AgentRuntime(provider: provider, directory: directory, resumeSession: resume, onEvent: callback)
         }) throws {
        self.root = root
        self.writer = writer
        self.checkpointStore = checkpoints
        self.factory = factory
        self.projectDirectory = projectDirectory
        self.submissionTimeout = submissionTimeout
        self.interruptTimeout = interruptTimeout
        self.changed = changed
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        callbacks.setSpecific(key: Self.callbackKey, value: ObjectIdentifier(self))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Listed before anything is queued, so a store that can't be read leaves no work
        // running after this fails.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        resumeRemovals()
        let now = Date()
        for file in files where file.pathExtension == "json" {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= AgentLimits.maxFrame else {
                    continue
                }
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == saved.snapshot.session.description else {
                    continue
                }
                // A conversation closed long ago goes, with everything kept for it.
                if saved.snapshot.status == .closed,
                   let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) > closedRetention {
                    writer.async { self.removeConversation(saved, file: file) }
                    continue
                }
                let entry = Entry(saved.snapshot, directory: saved.directory)
                // Agents ran in a provider process that ended with the previous server.
                let running = entry.snapshot.subagents?.filter { $0.status == .running }.count ?? 0
                if running > 0 {
                    entry.snapshot.items.append(AgentChatItem(kind: .notice,
                        text: AgentRuntime.stoppedAgents(running, because: "the server restarted")))
                }
                entry.snapshot.subagents = nil
                do {
                    entry.inbox = try AgentPromptInbox.load(root.appendingPathComponent("inbox/" + entry.snapshot.session.description + ".json"))
                    if !entry.inbox.records.isEmpty || entry.inbox.paused {
                        entry.snapshot.queuedPrompts = entry.inbox.visible
                        entry.snapshot.queuePaused = entry.inbox.paused
                    } else if entry.snapshot.queuedPrompts?.isEmpty == false {
                        throw AgentRuntimeError("The queue acceptance ledger is missing. Pending prompts have not been replayed.")
                    }
                } catch {
                    entry.inboxError = error.localizedDescription
                    entry.snapshot.queuePaused = true
                    entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Queue recovery failed: " + error.localizedDescription))
                }
                entry.hasSuccessfulTurn = saved.hasSuccessfulTurn ?? entry.hasSuccessfulTurn
                entry.archived = saved.archived == true
                entry.forkSource = saved.forkSource
                entry.forkPoint = saved.forkPoint
                entry.lastProviderMessage = saved.lastProviderMessage
                entry.turnForkPoints = saved.turnForkPoints ?? [:]
                entry.alwaysAllowedTools = Set(saved.alwaysAllowedTools ?? [])
                // Snapshots saved before tool bodies were stored once still carry both copies.
                for index in entry.snapshot.items.indices { Self.dropDuplicateDetail(&entry.snapshot.items[index]) }
                bound(entry)
                let cleared = recoverClearedCheckpoints(entry.snapshot)
                let archivedCheckpointIDs = cleared.archived.union(cleared.unknown)
                let checkpointDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
                    .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
                let existing = (try? FileManager.default.contentsOfDirectory(at: checkpointDirectory, includingPropertiesForKeys: nil)) ?? []
                let checkpointIDs = Set(existing.filter { $0.pathExtension == "json" }.map { file in
                    let name = file.deletingPathExtension().lastPathComponent
                    return name.hasPrefix("pending-") ? String(name.dropFirst(8)) : name
                }).subtracting(archivedCheckpointIDs)
                let sessionID = entry.snapshot.session
                writer.async { self.retainedCheckpointIDs[sessionID] = checkpointIDs }
                restoreCheckpoints(entry)
                if entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                    interrupted(entry, message: "Agent interrupted when the server stopped. Send a message to resume.")
                } else {
                    updateTurn(entry, status: entry.snapshot.status)
                }
                entries[entry.snapshot.session] = entry
                recordItemRevisions(entry)
                persist(entry)
            } catch {
                AgentLog.error("agent snapshot unavailable: \(file.lastPathComponent): \(error)")
            }
        }
        writer.async {
            self.reclaimAbandonedCopies()
            self.settleUnsettledPins()
            self.recordRepositories()
        }
    }

    /// Reports every conversation's activity again, before it returns.
    func publishActivity() {
        queue.sync { for entry in entries.values { notifyActivity(entry.snapshot, entry.directory) } }
        drainCallbacks()
    }

    private func notifyChanged(_ session: SessionId, _ revision: UInt64) {
        let changed = changed
        callbacks.async { changed(session, revision) }
    }

    private func notifyActivity(_ snapshot: AgentChatSnapshot, _ directory: String) {
        let activityChanged = activityChanged
        callbacks.async { activityChanged(snapshot, directory) }
    }

    /// Whether the caller is one of the host's callbacks.
    var onCallbackQueue: Bool { DispatchQueue.getSpecific(key: Self.callbackKey) == ObjectIdentifier(self) }

    /// Waits for the callbacks already queued, unless called from one.
    func drainCallbacks() {
        guard !onCallbackQueue else { return }
        callbacks.sync {}
    }

    var hasSessions: Bool {
        queue.sync { entries.values.contains { $0.snapshot.status != .closed || $0.runtime != nil || $0.submitting } }
    }

    func handle(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        try request.validate()
        let submissionContext: (SessionId, SessionId?)? = queue.sync {
            let id: SessionId
            switch request {
            case .submit(let session, _), .send(let session, _, _, _, _, _): id = session
            default: return nil
            }
            return (id, entries[id]?.snapshot.resetID)
        }
        if case .clear(let session, _, _) = request, let checkpoints = queue.sync(execute: { entries[session]?.checkpoints }) {
            let drained = DispatchGroup()
            drained.enter()
            checkpoints.async { drained.leave() }
            await clearStep?(.waiting)
            await withCheckedContinuation { finished in drained.notify(queue: .global(qos: .userInitiated)) { finished.resume() } }
            await clearStep?(.waited)
        }
        let request = try await resolvingSkill(request)
        try request.validate()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let (session, resetID) = submissionContext, entries[session]?.snapshot.resetID != resetID {
                        throw AgentRuntimeError("The conversation was cleared while this message was being prepared. Review the draft before sending it again.")
                    }
                    try begin(request, continuation: Reply(continuation))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Resolve on submission, so selected, typed, recalled, and retried skills agree.
    private func resolvingSkill(_ request: AgentChatRequest) async throws -> AgentChatRequest {
        let session: SessionId, text: String, provider: AgentChatProvider?, attachments: [AgentChatAttachment]
        switch request {
        case .submit(let id, let prompt): session = id; text = prompt.text; provider = prompt.provider; attachments = prompt.attachments
        case .send(let id, let value, _, _, let selected, let files): session = id; text = value; provider = selected; attachments = files ?? []
        default: return request
        }
        if case .submit(let id, let prompt) = request {
            let fingerprint = try AgentPromptInbox.fingerprint(prompt)
            if queue.sync(execute: { entries[id]?.inbox.records.contains { $0.id == prompt.id && $0.fingerprint == fingerprint } }) == true {
                return request
            }
        }
        guard let command = AgentSlashCommand(text: text), !command.isPath, !AgentSlashCommand.localNames.contains(command.name) else { return request }
        let snapshot = try queue.sync { () throws -> AgentChatSnapshot in
            guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
            return entry.snapshot
        }
        let selected = provider ?? snapshot.provider
        if !command.name.hasPrefix("skill:") {
            if selected == .claude, !AgentSlashCommand.unavailable(command.name),
               !(snapshot.commands ?? []).contains(command.name), let composerCatalog {
                let catalog = try await composerCatalog(.init(project: snapshot.project, provider: selected))
                queue.sync {
                    guard let entry = entries[session], entry.snapshot.resetID == snapshot.resetID else { return }
                    entry.snapshot.commandDescriptors = catalog.commands ?? entry.snapshot.commandDescriptors
                }
            }
            return request
        }
        guard let composerCatalog else { throw AgentRuntimeError("Skill discovery is unavailable on this server.") }
        let catalog = try await composerCatalog(.init(project: snapshot.project, provider: selected))
        let name = String(command.name.dropFirst(6))
        let attachment: AgentChatAttachment
        if let skill = catalog.skills.first(where: { $0.name == name }) {
            let directory = (skill.path.rawValue as NSString).deletingLastPathComponent
            let instructions = "Use the following skill for this request. Resolve relative resources from \(directory).\n\n" + skill.instructions
            attachment = AgentChatAttachment(id: "skill-instructions", name: "Skill-" + name + ".md", mimeType: "text/plain", data: Data(instructions.utf8))
        } else if selected == .claude, catalog.commands?.contains(where: { $0.names.contains(name) && $0.isSkill == true && !AgentSlashCommand.unavailable($0.name) && !AgentSlashCommand.unavailable(name) }) == true {
            attachment = AgentChatAttachment(id: "native-skill", name: "Skill-" + name + ".txt", mimeType: "text/plain", data: Data(name.utf8))
        } else {
            throw AgentRuntimeError("Skill \(name) was not found. Use /skills to choose an available skill.")
        }
        let files = attachments.filter { $0.id != "skill-instructions" && $0.id != "native-skill" } + [attachment]
        switch request {
        case .submit(let session, var prompt): prompt.attachments = files; return .submit(session: session, prompt: prompt)
        case .send(let session, let text, let model, let effort, let provider, _):
            return .send(session: session, text: text, model: model, reasoningEffort: effort, provider: provider, attachments: files)
        default: return request
        }
    }

    func attachment(_ request: AgentAttachmentRequest) async throws -> AgentAttachmentReply {
        try request.validate()
        let descriptor = queue.sync {
            entries[request.session]?.snapshot.items.first { $0.id == request.item }?.attachments?.first { $0.id == request.attachment }
        }
        guard let descriptor else { throw ServiceError(.badRequest, "Attachment not found in this conversation message") }
        let directory = root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(request.session.description, isDirectory: true)
            .appendingPathComponent(AgentToolImages.directoryName(item: request.item), isDirectory: true)
        return try await runBlocking {
            AgentAttachmentReply(attachment: try AgentAttachments.retrieve(descriptor, root: directory))
        }
    }

    func conversation(_ request: AgentConversationRequest) async throws -> AgentConversationReply {
        try request.validate()
        switch request {
        case .subagentSteps(let session, let toolUseID):
            let (items, shell) = try queue.sync { () throws -> ([AgentChatItem], (AgentChatItem, AgentSubagent)?) in
                guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                if let steps = entry.subagentSteps[toolUseID] { return (steps, nil) }
                guard let task = entry.snapshot.subagents?.first(where: { $0.toolUseID == toolUseID && $0.agentType == "Shell" }),
                      let item = entry.snapshot.items.last(where: { $0.id == toolUseID }) else { return ([], nil) }
                return ([], (item, task))
            }
            guard let (item, task) = shell else { return .subagentSteps(AgentSubagentSteps(toolUseID: toolUseID, items: items)) }
            let step = try await runBlocking { AgentBackgroundShell.step(item, task: task) }
            return .subagentSteps(AgentSubagentSteps(toolUseID: toolUseID, items: [step]))
        case .revert(let session, let checkpoint, let paths, let force):
            return .revert(try await revert(session: session, checkpoint: checkpoint, paths: paths, force: force))
        case .toolOutput(let session, let item):
            let lookup: (known: Bool, tool: AgentToolActivity?) = queue.sync {
                guard let entry = entries[session] else { return (false, nil) }
                return (true, entry.snapshot.items.first { $0.id == item }?.tool)
            }
            guard lookup.known else { throw ServiceError.unknownSession(session) }
            guard let tool = lookup.tool, let total = tool.fullOutputBytes else {
                throw ServiceError(.badRequest, "This tool's whole output isn't kept.")
            }
            let file = outputFile(session: session, item: item), command = tool.presentsCommand == true
            return .toolOutput(try await runBlocking {
                let data = try Data(contentsOf: file)
                // Bound it again: earlier versions kept outputs cut inside a character, and larger.
                let kept = AgentReplyBounds.bounded(AgentReplyBounds.wholeCharacters(data), maximumBytes: AgentToolOutput.maximumBytes,
                                                    maximumEncodedBytes: AgentToolOutput.maximumEncodedBytes, keepingEnd: command)
                return AgentToolOutput(item: item, text: kept.text, truncated: kept.cut || data.count < total)
            })
        case .fork(let session, let from, let project, let at):
            return .forked(try queue.sync { try fork(session, from: from, into: project, at: at) })
        case .earlier(let session, let before, let limit):
            guard queue.sync(execute: { entries[session] != nil }) else { throw ServiceError.unknownSession(session) }
            return .earlier(try await earlierItems(session: session, before: before, limit: limit))
        case .readSince(let session, let revision):
            return .delta(try queue.sync { () throws -> AgentChatDelta in
                guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                return delta(entry, since: revision)
            })
        }
    }

    /// Restores files a turn changed to their state before it, on the conversation's
    /// checkpoint queue so the sessions queue keeps serving: after checkpoints already
    /// being taken, and before a turn sent later starts. Refuses, changing nothing, when
    /// a target file was changed since the turn, unless `force`, and while the agent works.
    private func revert(session: SessionId, checkpoint: String, paths: [String]?, force: Bool) async throws -> AgentRevertReply {
        let file = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
            .appendingPathComponent(checkpoint + ".json")
        let store = checkpointStore
        // The folder, and where each provider that may still run works now, read off the
        // sessions queue: either may be on a slow volume.
        let (directory, runtimes) = queue.sync { (entries[session]?.directory, entries.values.compactMap(\.runtime)) }
        let candidates = (runtimes + retiring.withLock { Array($0.values) }).flatMap { $0.providerProcesses() } + otherProviderProcesses()
        let scope: AgentRevertScope? = try await runBlocking { directory.map { AgentRevertScope(directory: $0, candidates: candidates) } }
        return try await withCheckedThrowingContinuation { continuation in
            // Admitted and queued in one step, so a turn sent after it starts after it. Never
            // while stopping, as shutdown then waits for it to be applied and recorded, nor
            // during a clear, which waits for it instead.
            queue.async { [self] in
                do {
                    guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
                    guard let entry = entries[session], entry.snapshot.turns?.contains(where: { $0.checkpoint?.id == checkpoint }) == true else {
                        throw ServiceError(.badRequest, "Checkpoint not found in this conversation")
                    }
                    guard !entry.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
                    // An agent at work, in the foreground or the background, may be changing the same files.
                    guard !entry.submitting, entry.deliveryID == nil, entry.snapshot.status != .working, entry.snapshot.status != .waiting,
                          entry.snapshot.subagents?.contains(where: { $0.status == .running }) != true else {
                        throw ServiceError(.badRequest, "Stop active work before reverting.")
                    }
                    // A provider stopping in the same folder, or in one inside or around it,
                    // whichever conversation's, may still change its files.
                    if let scope {
                        let stopping = retiring.withLock { $0.values.contains { $0.mayRun(in: scope) } }
                            || entries.values.contains { $0.runtime?.isStopping(in: scope) == true }
                            || otherProvidersMayRun(scope)
                        guard !stopping else { throw AgentRuntimeError("The agent is still stopping. Try again shortly.") }
                    }
                    entry.reverts += 1
                    storeWork.enter()
                    revertAdmitted?()
                    // Applied and recorded on Dispatch, so shutdown, which may block every
                    // Swift task worker, never waits on one.
                    entry.checkpoints.async { [self] in
                        defer { storeWork.leave() }
                        let result = Result { () throws -> AgentRevertReply in
                            let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
                            let changed = Set(record.files.map(\.path))
                            let targets = paths ?? record.files.map(\.path)
                            guard !targets.isEmpty, targets.allSatisfy(changed.contains) else {
                                throw ServiceError(.badRequest, "Only files this turn changed can be reverted")
                            }
                            if !force {
                                let conflicts = try store.changedSince(record.after, paths: targets)
                                if !conflicts.isEmpty { return AgentRevertReply(conflicts: conflicts) }
                            }
                            try store.restore(record.before, paths: targets)
                            return AgentRevertReply(reverted: targets)
                        }
                        queue.sync {
                            entry.reverts -= 1
                            guard case .success(let reply) = result, !reply.reverted.isEmpty,
                                  entries[session] === entry, entry.snapshot.status != .closed else { return }
                            let count = reply.reverted.count
                            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice,
                                text: "Reverted \(count == 1 ? "1 file" : "\(count) files") to before a turn."), entry: entry))
                            touch(entry)
                            persist(entry)
                        }
                        continuation.resume(with: result)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func checkpoint(_ request: AgentCheckpointRequest) async throws -> AgentCheckpointReply {
        try request.validate()
        let known = queue.sync {
            entries[request.session]?.snapshot.turns?.contains { $0.checkpoint?.id == request.checkpoint } ?? false
        }
        guard known else { throw ServiceError(.badRequest, "Checkpoint not found in this conversation") }
        let file = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(request.session.description, isDirectory: true)
            .appendingPathComponent(request.checkpoint + ".json")
        let store = checkpointStore
        return try await runBlocking {
            let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
            guard request.offset <= record.files.count else { throw ServiceError(.badRequest, "Invalid checkpoint page") }
            let end = min(record.files.count, request.offset + min(128, record.files.count - request.offset))
            let files = Array(record.files[request.offset..<end])
            var diff: GitDiff?
            if let path = request.path {
                guard let file = record.files.first(where: { $0.path == path }) else {
                    throw ServiceError(.badRequest, "File is not part of this checkpoint")
                }
                var content = try store.diff(from: record.before, to: record.after, path: path)
                content.additions = file.additions ?? 0
                content.deletions = file.deletions ?? 0
                content.binary = file.additions == nil || file.deletions == nil
                if content.rows.count > 8000 {
                    content.rows = Array(content.rows.prefix(8000))
                    content.truncated = true
                }
                diff = content
            }
            let reply = AgentCheckpointReply(checkpoint: request.checkpoint, files: files,
                totalFiles: record.files.count, nextOffset: end < record.files.count ? end : nil, path: request.path, diff: diff)
            try reply.validate()
            return reply
        }
    }

    private func begin(_ request: AgentChatRequest,
                       continuation: Reply, deliveryID: String? = nil) throws {
        if case .create(let id, let project, let provider) = request {
            if let entry = entries[id] {
                guard entry.snapshot.project == project else {
                    throw ServiceError(.badRequest, "This agent session ID is already in use")
                }
                continuation.resume(returning: entry.snapshot)
                return
            }
            guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
            let directory = try projectDirectory(project)
            try checkDirectory(directory)
            let entry = Entry(AgentChatSnapshot(session: id, project: project, provider: provider, accessMode: defaultAccess), directory: directory)
            entries[id] = entry
            touch(entry)
            persist(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .fork(let id, let from, let project) = request {
            continuation.resume(returning: try fork(id, from: from, into: project))
            return
        }
        let id: SessionId
        switch request {
        case .clear(let session, _, _), .read(let session), .send(let session, _, _, _, _, _), .approve(let session, _, _, _, _),
             .interrupt(let session), .close(let session), .setAccess(let session, _), .setPlan(let session, _): id = session
        case .submit(let session, _), .editQueued(let session, _, _, _, _), .removeQueued(let session, _, _),
             .deliverQueued(let session, _, _), .moveQueued(let session, _, _, _), .resumeQueue(let session), .answer(let session, _, _, _): id = session
        case .create, .fork: throw ServiceError(.badRequest, "Unexpected create")
        }
        guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
        if case .read = request {
            continuation.resume(returning: entry.snapshot)
            return
        }
        guard !entry.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
        if case .clear(_, let archive, let revision) = request {
            try clear(entry, archive: archive, revision: revision, reply: continuation)
            return
        }
        if case .close = request {
            // Shutdown already saves every conversation as it stands.
            if !stopping { close(entry) }
            continuation.resume(returning: entry.snapshot)
            return
        }
        guard !stopping, entry.snapshot.status != .closed else {
            throw ServiceError(.badRequest, "The agent session is closed or the server is stopping")
        }
        if case .submit(_, let prompt) = request,
           let existing = entry.inbox.records.first(where: { $0.id == prompt.id }) {
            guard existing.fingerprint == (try AgentPromptInbox.fingerprint(prompt)) else {
                throw AgentRuntimeError("This submission ID belongs to a different prompt.")
            }
            continuation.resume(returning: entry.snapshot)
            return
        }
        let submitted: (String, AgentChatProvider, Bool)?
        switch request {
        case .submit(_, let prompt): submitted = (prompt.text, prompt.provider, !prompt.attachments.isEmpty)
        case .send(_, let text, _, _, let provider, let attachments): submitted = (text, provider ?? entry.snapshot.provider, attachments?.isEmpty == false)
        default: submitted = nil
        }
        if let (text, provider, attachments) = submitted, let command = AgentSlashCommand(text: text), !command.isPath {
            let names = provider == .codex ? ["compact", "review"] : (entry.snapshot.commands ?? []) + (entry.snapshot.commandDescriptors?.flatMap(\.names) ?? [])
            if let error = command.validationError(provider: provider, commands: names, hasAttachments: attachments,
                descriptors: entry.snapshot.commandDescriptors ?? []) { throw AgentRuntimeError(error) }
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting,
                  (entry.inbox.visible.isEmpty || (deliveryID != nil && entry.deliveryID == deliveryID)) else { throw AgentRuntimeError("Run commands after active and queued work finishes.") }
        }
        if try handleInbox(request, entry: entry) {
            writer.async { [self] in
                queue.async {
                    if let error = entry.inboxError { continuation.resume(throwing: AgentRuntimeError(error)) }
                    else { continuation.resume(returning: entry.snapshot) }
                }
            }
            return
        }
        if case .interrupt = request {
            entry.deliveryCancelled = true
            if entry.steering, let pending = entry.pendingSubmission {
                pending.stopped = true
                pending.delivery?.cancel()
            }
            try mutateInbox(entry) { $0.paused = true }
            if !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting {
                // Nothing is running, as when Stop races a turn that just finished:
                // the stop only holds the queue.
                continuation.resume(returning: entry.snapshot)
                return
            }
        }
        if case .setPlan(_, let enabled) = request {
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting else {
                throw ServiceError(.badRequest, "Stop the current response before changing plan mode.")
            }
            entry.snapshot.planMode = enabled
            touch(entry)
            persist(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .setAccess(_, let mode) = request {
            entry.snapshot.accessMode = mode
            // Ask means asking for everything, including tools allowed earlier.
            if mode == .ask { entry.alwaysAllowedTools.removeAll() }
            touch(entry)
            persist(entry)
            if let runtime = entry.runtime {
                configureAccess(entry, runtime: runtime, mode: mode)
            } else {
                continuation.resume(returning: entry.snapshot)
                return
            }
        }
        if case .interrupt = request, entry.submitting, !entry.steering {
            // No authoritative turn exists yet, so there is nothing to interrupt
            // gracefully. Fence the startup and settle its reply before stopping it.
            stopTurn(entry)
            settleSubmission(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        // Attachment bytes are checked here and written on the writer, queued now so a clear
        // or cleanup asked for later finds them whole; up to 8 MiB of disk writes never
        // hold the sessions queue.
        var turnAttachmentFiles: (attachments: [AgentChatAttachment], staging: AgentStaging?)?
        if case .send(_, let text, let model, let effort, let requestedProvider, let attachments) = request {
            guard entry.deliveryID == nil || entry.deliveryID == deliveryID else {
                throw ServiceError(.badRequest, "A queued prompt is being delivered.")
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            if !entry.submitting, entry.snapshot.status == .working, let runtime = entry.runtime {
                guard requestedProvider == nil || requestedProvider == entry.snapshot.provider,
                      model == entry.snapshot.model, effort == entry.snapshot.reasoningEffort else {
                    throw ServiceError(.badRequest, "Model and reasoning changes apply after the current response.")
                }
                let userID = deliveryID ?? UUID().uuidString
                let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent(id.description).appendingPathComponent(userID)
                try AgentAttachments.validateForStaging(attachments ?? [])
                let staging = stage(attachments ?? [], root: attachmentRoot)
                let generation = entry.generation
                entry.submitting = true
                entry.steering = true
                let pending = PendingReply(continuation, delivery: AgentDelivery())
                entry.pendingSubmission = pending
                followUpAdmitted?()
                queue.asyncAfter(deadline: .now() + submissionTimeout) { [self] in
                    guard !pending.finished else { return }
                    pending.task?.cancel()
                    receive(.failure("Follow-up delivery timed out. It may have reached the agent; review the conversation before retrying."), session: id, generation: generation)
                    settleSubmission(entry)
                }
                pending.task = Task {
                    do {
                        let staged = try await staging?.value() ?? []
                        // Handed over only if Stop hasn't cancelled it, however late this runs.
                        guard let delivery = pending.delivery else { throw AgentDeliveryNotStarted() }
                        try await runtime.steer(text: text, attachments: staged, delivery: delivery)
                        self.queue.async {
                            guard !pending.finished else { return }
                            pending.finished = true
                            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                            guard entry.generation == generation else {
                                continuation.resume(throwing: AgentRuntimeError("The conversation changed before the message was accepted."))
                                return
                            }
                            entry.submitting = false
                            entry.steering = false
                            entry.snapshot.items.append(self.observedItem(.init(id: userID, kind: .user, text: text,
                                attachments: attachments?.map(\.descriptor)), entry: entry))
                            self.touch(entry)
                            self.persist(entry)
                            continuation.resume(returning: entry.snapshot)
                        }
                    } catch {
                        self.queue.async {
                            guard !pending.finished else { return }
                            pending.finished = true
                            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                            if entry.generation == generation { entry.submitting = false; entry.steering = false }
                            self.write { try? FileManager.default.removeItem(at: attachmentRoot) }
                            // Never handed over: refused for the stop, or the stopped turn had ended.
                            let stopped = pending.stopped || (deliveryID != nil && entry.deliveryCancelled)
                            if error is AgentDeliveryNotStarted || error is AgentFollowUpRefused || (stopped && error is AgentTurnFinishedError) {
                                continuation.resume(throwing: AgentDeliveryNotStarted())
                                return
                            }
                            // The turn ended while the follow-up was on its way; its idle
                            // status is already applied, so the message starts a new turn,
                            // unless the user stopped it: then it may have reached the agent.
                            guard !pending.stopped, error is AgentTurnFinishedError, entry.generation == generation,
                                  entry.snapshot.status != .working else {
                                continuation.resume(throwing: error)
                                return
                            }
                            do { try self.begin(request, continuation: continuation, deliveryID: deliveryID) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                }
                return
            }
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting else {
                throw ServiceError(.badRequest, "The agent is already handling a message")
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            let provider = requestedProvider ?? entry.snapshot.provider
            if provider != entry.snapshot.provider {
                guard entry.snapshot.providerSession == nil, !entry.hasSuccessfulTurn,
                      entry.snapshot.status == .idle || entry.snapshot.status == .failed else {
                    throw ServiceError(.badRequest, "An established conversation cannot switch providers. Open a new agent pane.")
                }
            }
            if let effort, !effort.isAccepted(provider: provider, model: model) {
                throw ServiceError(.badRequest, "\(provider.name) does not support \(effort.title) reasoning for this model")
            }
            let restart = provider != entry.snapshot.provider
                || (provider == .claude && (model != entry.snapshot.model || effort != entry.snapshot.reasoningEffort))
            if restart {
                guard !entry.hasSuccessfulTurn || entry.snapshot.providerSession != nil else {
                    throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
                }
            }
            if entry.runtime == nil, entry.hasSuccessfulTurn, entry.snapshot.providerSession == nil {
                throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
            }
            let userID = deliveryID ?? UUID().uuidString
            let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
                .appendingPathComponent(userID, isDirectory: true)
            do {
                try AgentAttachments.validateForStaging(attachments ?? [])
                turnAttachmentFiles = (attachments ?? [], stage(attachments ?? [], root: attachmentRoot))
            } catch {
                throw ServiceError(.badRequest, error.localizedDescription)
            }
            if restart, entry.runtime != nil {
                retireRuntime(entry, reason: provider != entry.snapshot.provider ? "the provider changed"
                    : "the model or reasoning effort changed, which restarts Claude")
            }
            if provider != entry.snapshot.provider || model != entry.snapshot.model {
                entry.snapshot.contextUsage = nil
                entry.snapshot.resolvedModel = nil
            }
            entry.snapshot.provider = provider
            let user = AgentChatItem(id: userID, kind: .user, text: text,
                                     attachments: attachments?.map(\.descriptor))
            entry.snapshot.items.append(observedItem(user, entry: entry))
            entry.snapshot.turns = (entry.snapshot.turns ?? []) + [AgentChatTurn(userItemID: user.id, startedAt: Date())]
            if let session = entry.snapshot.providerSession, let message = entry.lastProviderMessage {
                entry.turnForkPoints[user.id] = ForkPoint(session: session, message: message)
            }
            let captureDirectory = entry.directory
            let pendingDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
            entry.baseline = nil
            if capturesCheckpoints {
                let baseline = CheckpointBaseline(), store = checkpointStore
                let checkpointsRoot = root.appendingPathComponent("checkpoints", isDirectory: true)
                entry.baseline = baseline
                storeWork.enter()
                // Queued after the last turn's checkpoint, so it starts where that one ended.
                entry.checkpoints.async { [storeWork] in
                    defer { storeWork.leave() }
                    let before: AgentCheckpointStore.Snapshot
                    do { before = try store.capture(directory: captureDirectory) } catch {
                        Self.keepUnsettled(error, in: checkpointsRoot)
                        return baseline.resolve(nil)
                    }
                    do {
                        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(AgentCheckpointPending(turnID: user.id, before: before))
                            .write(to: pendingDirectory.appendingPathComponent("pending-" + user.id + ".json"), options: .atomic)
                        baseline.resolve(before)
                    } catch {
                        Self.discard(before, store: store, in: checkpointsRoot)
                        baseline.resolve(nil)
                    }
                }
            }
            entry.snapshot.model = model
            entry.snapshot.reasoningEffort = effort
            entry.snapshot.status = .working
            entry.submitting = true
            touch(entry)
            persist(entry)
        }
        if case .answer(_, let request, let answers, let cancelled) = request {
            if entry.snapshot.items.contains(where: { $0.id == request && $0.questionnaire != nil && $0.isComplete }) {
                continuation.resume(returning: entry.snapshot)
                return
            }
            guard !entry.approving.contains(request), let item = entry.snapshot.items.first(where: { $0.id == request && !$0.isComplete }),
                  let form = item.questionnaire, entry.runtime != nil else {
                throw ServiceError(.badRequest, "This question is no longer pending.")
            }
            try form.validate(answers: answers, cancelled: cancelled)
            entry.approving.insert(request)
        }
        var alwaysTool: String?
        if case .approve(_, let request, _, let always, _) = request {
            guard !entry.submitting, entry.snapshot.status == .waiting,
                  !entry.approving.contains(request),
                  let item = entry.snapshot.items.first(where: { $0.id == request && $0.kind == .approval && !$0.isComplete && $0.questionnaire == nil }) else {
                throw ServiceError(.badRequest, "This approval is no longer pending")
            }
            if always == true {
                guard entry.snapshot.provider == .claude, AgentApprovalScope.canAlwaysAllow(item.text) else {
                    throw ServiceError(.badRequest, "This request can only be allowed once.")
                }
                alwaysTool = item.text
            }
        }
        if entry.runtime == nil {
            guard case .send = request else {
                continuation.resume(returning: entry.snapshot)
                return
            }
            let generation = entry.generation
            let initialLaunch = launchContext(id, entry.snapshot.project)
            if let catalog = applicationToolSignature {
                let signature = SHA256.hash(data: Data((catalog + "\n" + (initialLaunch.instructions ?? "")).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                if entry.snapshot.applicationToolSignature != signature {
                    if entry.snapshot.providerSession != nil {
                        entry.snapshot.providerSession = nil
                        entry.forkSource = nil; entry.forkPoint = nil
                        entry.snapshot.items.append(AgentChatItem(kind: .notice,
                            text: "Application capabilities changed. Started a fresh provider thread; your local conversation is retained. Inspect the current application state before continuing."))
                    }
                    entry.snapshot.applicationToolSignature = signature
                }
            }
            entry.runtime = factory(entry.snapshot.provider, entry.directory, entry.snapshot.providerSession) {
                [weak self] event in
                self?.queue.async { [weak self] in self?.receive(event, session: id, generation: generation) }
            }
            if let runtime = entry.runtime {
                var launch = initialLaunch
                launch.forkSource = entry.forkSource
                launch.forkPoint = entry.forkPoint
                runtime.prepare(launch)
                configureAccess(entry, runtime: runtime, mode: entry.snapshot.accessMode ?? .standard)
            }
        }
        guard let runtime = entry.runtime else { throw ServiceError(.badRequest, "Agent unavailable") }
        let generation = entry.generation
        let model = entry.snapshot.model
        let effort = entry.snapshot.reasoningEffort
        let accessTask = entry.accessTask
        let baseline = entry.baseline
        if case .approve(_, let request, _, _, _) = request { entry.approving.insert(request) }
        if case .interrupt = request {
            guard entry.interrupting == nil else { throw ServiceError(.badRequest, "An interrupt is already pending") }
            entry.interrupting = UUID()
        }
        let pending = PendingReply(continuation)
        let turnAttachments = turnAttachmentFiles
        if case .send = request { entry.pendingSubmission = pending }
        queue.asyncAfter(deadline: .now() + submissionTimeout) { [self] in
            guard !pending.finished else { return }
            pending.finished = true
            pending.task?.cancel()
            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
            if entry.generation == generation, !stopping, entry.snapshot.status != .closed {
                receive(.failure("Agent submission timed out. The agent was stopped; send a message to retry."),
                        session: id, generation: generation)
            }
            continuation.resume(returning: entry.snapshot)
        }
        let planMode = entry.snapshot.planMode == true
        pending.task = Task { [self] in
            guard !Task.isCancelled else { return }
            let failure: Error?
            do {
                switch request {
                case .send(_, let text, _, _, _, _):
                    try await accessTask?.value
                    _ = await baseline?.value()
                    try Task.checkCancellation()
                    try await runtime.setPlan(planMode)
                    var staged: [StagedAgentAttachment] = []
                    let invocation = AgentSlashCommand(text: text)
                    let skillRequest = invocation?.name.hasPrefix("skill:") == true
                    let nativeSkill = skillRequest ? turnAttachments?.attachments.first(where: { $0.id == "native-skill" }) : nil
                    if let staging = turnAttachments?.staging { staged = try await staging.value() }
                    let delivered: String
                    if let nativeSkill {
                        delivered = "/" + String(decoding: nativeSkill.data, as: UTF8.self) + " " + (invocation?.arguments ?? "")
                    } else if skillRequest {
                        delivered = "Use the attached skill instructions for this request. " + (invocation?.arguments ?? "")
                    } else { delivered = text }
                    try await runtime.send(text: delivered, model: model, reasoningEffort: effort, attachments: staged.filter { nativeSkill == nil || $0.attachment.id != "native-skill" })
                case .setAccess: try await accessTask?.value
                case .approve(_, let request, let allow, let always, let reason):
                    try await runtime.approve(request: request, allow: allow, always: always == true, reason: reason)
                case .answer(_, let request, let answers, let cancelled): try await runtime.answer(request: request, answers: answers, cancelled: cancelled)
                case .interrupt: try await runtime.interrupt()
                default: break
                }
                failure = nil
            } catch { failure = error }
            queue.async { [self] in
                guard !pending.finished else { return }
                pending.finished = true
                if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                // Synchronous runtime callbacks were enqueued before this completion.
                if entry.generation == generation, entry.snapshot.status != .closed, !stopping {
                    if case .send = request { entry.submitting = false }
                    if case .approve(_, let request, _, _, _) = request { entry.approving.remove(request) }
                    if case .answer(_, let request, _, _) = request { entry.approving.remove(request) }
                    if let failure {
                        if case .interrupt = request {
                            // The provider refused or couldn't take the stop, so its process is
                            // stopped instead; a stop never leaves the turn working.
                            entry.snapshot.items.append(AgentChatItem(kind: .notice,
                                text: "The agent didn't take the stop (\(failure.localizedDescription)), so it was ended."))
                            if entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                                stopTurn(entry)
                            } else {
                                entry.interrupting = nil
                                touch(entry)
                            }
                        } else {
                            receive(.failure(failure.localizedDescription), session: id, generation: generation)
                        }
                    } else if case .interrupt = request {
                        if let interruption = entry.interrupting {
                            if entry.snapshot.status == .idle {
                                entry.interrupting = nil
                                entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Agent interrupted."))
                            } else {
                                // The stop button already shows the request; the transcript
                                // only records the outcome.
                                queue.asyncAfter(deadline: .now() + interruptTimeout) { [self] in
                                    guard entry.generation == generation, entry.interrupting == interruption,
                                          !stopping, entry.snapshot.status != .closed else { return }
                                    stopTurn(entry)
                                    drainInbox(entry)
                                }
                            }
                            touch(entry)
                        }
                    } else if case .approve(_, let approval, _, _, _) = request {
                        if let alwaysTool { entry.alwaysAllowedTools.insert(alwaysTool) }
                        if let index = entry.snapshot.items.firstIndex(where: { $0.id == approval }) {
                            entry.snapshot.items[index].isComplete = true
                        }
                        if entry.snapshot.status == .waiting,
                           !entry.snapshot.items.contains(where: { $0.kind == .approval && !$0.isComplete }) {
                            entry.snapshot.status = .working
                            updateTurn(entry, status: .working)
                        }
                        touch(entry)
                    }
                    persist(entry)
                }
                continuation.resume(returning: entry.snapshot)
                self.drainInbox(entry)
            }
        }
    }

    private func receive(_ event: AgentRuntimeEvent, session: SessionId, generation: UUID) {
        guard !stopping, let entry = entries[session], entry.generation == generation,
              entry.snapshot.status != .closed else { return }
        if entry.stagingToolImages {
            guard !entry.deferredEventOverflow else { return }
            let bytes = deferredBytes(event)
            guard entry.deferredEvents.count < 512,
                  bytes <= Self.maximumDeferredEventBytes - entry.deferredEventBytes else {
                // Stop the producer instead of retaining an unbounded stream
                // behind slow disk I/O. The failure follows the in-flight image.
                entry.deferredEventOverflow = true
                entry.deferredEvents = [.failure("Agent output exceeded the pending media limit. Send a message to resume.")]
                entry.deferredEventBytes = 0
                retire(entry.runtime, of: entry)
                return
            }
            entry.deferredEvents.append(event)
            entry.deferredEventBytes += bytes
            return
        }
        if case .toolItem(let item, let images) = event {
            guard item.id.utf8.count <= 1024 else { return }
            if item.tool?.isApplicationTool != true,
               entry.snapshot.items.first(where: { $0.id == item.id })?.tool?.isApplicationTool == true { return }
            let directory = root.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(session.description, isDirectory: true)
                .appendingPathComponent(AgentToolImages.directoryName(item: item.id), isDirectory: true)
            entry.stagingToolImages = true
            let stage = stageToolImages, fence = fence
            // On the writer, in order with clears and cleanups of the conversation's files.
            writer.async { [weak self] in
                var stored = item
                do { guard try fence.write({ try stage(images, directory) }) else { return } }
                catch { stored.detail = (stored.detail ?? "") + "\nImage storage failed: " + error.localizedDescription }
                let completed = stored
                self?.queue.async { [weak self] in
                    guard let self, !self.stopping, entry.generation == generation,
                          entry.snapshot.status != .closed else { return }
                    let deferred = entry.deferredEvents
                    entry.stagingToolImages = false
                    entry.deferredEvents.removeAll()
                    entry.deferredEventBytes = 0
                    entry.deferredEventOverflow = false
                    self.receive(.item(completed), session: session, generation: generation)
                    for event in deferred { self.receive(event, session: session, generation: generation) }
                }
            }
            return
        }
        switch event {
        case .toolItem: return
        case .status(.closed) where entry.interrupting != nil:
            // A runtime with no turn to interrupt yet, such as a Codex compaction
            // that has not started, stops its process. The conversation carries on.
            stopTurn(entry)
            settleSubmission(entry)
            drainInbox(entry)
            return
        case .item(var item):
            guard item.id.utf8.count <= 1024 else { return }
            if item.tool?.isApplicationTool != true,
               entry.snapshot.items.first(where: { $0.id == item.id })?.tool?.isApplicationTool == true { return }
            keepFullOutput(&item, entry: entry)
            if item.kind == .approval, !item.isComplete,
               !entry.snapshot.items.contains(where: { $0.id == item.id }),
               entry.snapshot.items.filter({ $0.kind == .approval && !$0.isComplete }).count >= 128 {
                receive(.failure("Too many pending approvals. The agent was stopped."), session: session,
                        generation: generation)
                return
            }
            if let index = entry.snapshot.items.firstIndex(where: { $0.id == item.id }) {
                entry.snapshot.items[index] = observedItem(item, entry: entry, previous: entry.snapshot.items[index])
            } else { entry.snapshot.items.append(observedItem(item, entry: entry)) }
        case .itemUpdate(let item):
            guard let index = entry.snapshot.items.firstIndex(where: { $0.id == item.id }) else { return }
            entry.snapshot.items[index] = observedItem(item, entry: entry, previous: entry.snapshot.items[index])
        case .textDelta(let id, let text):
            guard id.utf8.count <= 1024 else { return }
            if let index = entry.snapshot.items.firstIndex(where: { $0.id == id }) {
                entry.snapshot.items[index].text += text
                entry.snapshot.items[index].updatedAt = Date()
            } else {
                entry.snapshot.items.append(observedItem(AgentChatItem(id: id, kind: .assistant,
                                                         text: text, isComplete: false), entry: entry))
            }
        case .status(let status):
            if status == .idle, entry.interrupting == nil,
               entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                entry.hasSuccessfulTurn = true
            }
            entry.snapshot.status = status
            let outcome: AgentChatTurn.Outcome? = status == .idle ? (entry.interrupting == nil ? .completed : .interrupted)
                : status == .failed ? .failed : status == .closed ? .cancelled : nil
            updateTurn(entry, status: status, outcome: outcome)
            if status == .idle, entry.interrupting != nil {
                entry.interrupting = nil
                entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Agent interrupted."))
            }
            if status == .failed { retireRuntime(entry, reason: "the provider stopped") }
            if status == .closed { retireRuntime(entry, reason: entry.interrupting == nil ? "the provider stopped" : nil) }
            if status == .idle || status == .failed || status == .closed {
                Self.finishItems(&entry.snapshot.items)
                // A retry ends with its turn; a usage warning stays until the provider changes it.
                if entry.snapshot.activity?.kind == .retrying || entry.snapshot.activity?.kind == .rateLimited { entry.snapshot.activity = nil }
            }
        case .providerSession(let id):
            guard id.utf8.count <= 4096 else {
                receive(.failure("The agent returned an invalid session identifier."), session: session,
                        generation: generation)
                return
            }
            guard entry.snapshot.providerSession != id else { return }
            entry.snapshot.providerSession = id
            entry.forkSource = nil
            entry.forkPoint = nil
            entry.lastProviderMessage = nil
        case .providerMessage(let id):
            guard id.utf8.count <= 4096 else { return }
            entry.lastProviderMessage = id
            return
        case .contextUsage(let usage):
            guard usage.usedTokens >= 0, usage.contextWindow.map({ $0 > 0 }) ?? true,
                  entry.snapshot.contextUsage != usage else { return }
            entry.snapshot.contextUsage = usage
        case .subagents(let subagents):
            let listed = subagents.isEmpty ? nil : subagents.prefix(AgentSubagent.maxCount).map { agent in
                var agent = agent
                agent.steps = agent.toolUseID.flatMap { entry.subagentSteps[$0]?.count }
                return agent
            }
            guard entry.snapshot.subagents != listed else { return }
            entry.snapshot.subagents = listed
        case .subagentSteps(let toolUseID, let items):
            guard toolUseID.utf8.count <= 1024 else { return }
            if entry.subagentSteps[toolUseID] == nil, entry.subagentSteps.count >= AgentSubagentTranscript.maxAgents,
               let oldest = entry.subagentSteps.keys.first(where: { key in
                   !(entry.snapshot.subagents ?? []).contains { $0.toolUseID == key && $0.status == .running }
               }) {
                entry.subagentSteps.removeValue(forKey: oldest)
            }
            entry.subagentSteps[toolUseID] = items
            guard let index = entry.snapshot.subagents?.firstIndex(where: { $0.toolUseID == toolUseID }),
                  entry.snapshot.subagents?[index].steps != items.count else { return }
            entry.snapshot.subagents?[index].steps = items.count
        case .turnUsage(let usage):
            guard let index = entry.snapshot.turns?.indices.last, entry.snapshot.turns?[index].completedAt == nil else { return }
            entry.snapshot.turns?[index].usage = usage
        case .activity(let activity):
            guard entry.snapshot.activity != activity else { return }
            entry.snapshot.activity = activity
        case .providerTurn(let reason):
            // A turn the provider began itself gets a record like a sent one, so the
            // conversation shows it working and Stop can end it. A send in flight
            // already owns the turn; the runtime holds it until this one ends.
            guard entry.snapshot.status == .idle, !entry.submitting, entry.deliveryID == nil else { return }
            let anchor = observedItem(AgentChatItem(kind: .user, text: String(reason.prefix(1024)),
                workContext: .init(itemType: AgentChatItem.providerTurnType)), entry: entry)
            entry.snapshot.items.append(anchor)
            entry.snapshot.turns = (entry.snapshot.turns ?? []) + [AgentChatTurn(userItemID: anchor.id, startedAt: Date())]
            entry.snapshot.status = .working
            updateTurn(entry, status: .working)
        case .planMode(let enabled):
            entry.snapshot.planMode = enabled
            persist(entry)
        case .commandDescriptors(let descriptors):
            entry.snapshot.commandDescriptors = Array(descriptors.filter(\.isValid).prefix(256))
        case .commands(let commands):
            entry.snapshot.commands = Array(commands.filter {
                !$0.isEmpty && $0.utf8.count <= 128 &&
                $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
            }.prefix(256))
        case .resolvedModel(let model):
            guard !model.isEmpty, model.utf8.count <= 256, !model.contains("\0"),
                  entry.snapshot.resolvedModel != model else { return }
            entry.snapshot.resolvedModel = model
        case .failure(let message):
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed, outcome: .failed)
            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: message,
                workContext: .init(itemType: "error", sourceStatus: "failed")), entry: entry))
            retireRuntime(entry, reason: "the turn failed")
            Self.finishItems(&entry.snapshot.items)
        }
        touch(entry)
        if entry.snapshot.status == .idle || entry.snapshot.status == .failed || entry.snapshot.status == .closed {
            persist(entry)
        }
        if entry.snapshot.status == .failed || entry.snapshot.status == .closed {
            settleSubmission(entry)
            do { try mutateInbox(entry) { $0.paused = true } }
            catch { entry.inboxError = error.localizedDescription }
        }
        drainInbox(entry)
        if case .providerSession = event { persist(entry) }
    }

    /// A new conversation `id` holding `from`'s transcript and choices. Its
    /// provider forks `from`'s conversation on the first message, so neither
    /// sees what the other says next. Claude forks at the message `from` had
    /// reached when the fork was made; Codex forks the whole thread as it is
    /// at the first message.
    private func fork(_ id: SessionId, from: SessionId, into project: ProjectId?) throws -> AgentChatSnapshot {
        guard let source = entries[from] else { throw ServiceError.unknownSession(from) }
        let project = project ?? source.snapshot.project
        if let entry = entries[id] {
            guard entry.snapshot.project == project else {
                throw ServiceError(.badRequest, "This agent session ID is already in use")
            }
            return entry.snapshot
        }
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        let folder = try projectDirectory(project)
        // A fork in its source's project keeps working where the source does.
        let directory = project == source.snapshot.project ? source.directory : folder
        try checkDirectory(directory)
        var snapshot = source.snapshot
        snapshot.session = id
        snapshot.project = project
        snapshot.revision = 0
        snapshot.status = .idle
        snapshot.turns = nil
        snapshot.items = snapshot.items.filter { $0.kind != .approval || $0.isComplete }
        Self.finishItems(&snapshot.items)
        let entry = Entry(snapshot, directory: directory)
        entry.hasSuccessfulTurn = source.hasSuccessfulTurn
        if let pending = source.forkSource {
            entry.forkSource = pending
            entry.forkPoint = source.forkPoint
        } else {
            entry.forkSource = source.snapshot.providerSession
            entry.forkPoint = source.lastProviderMessage
        }
        entries[id] = entry
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    /// A new conversation `id` with what `from` said before its user message `at`. Claude
    /// resumes `from`'s provider conversation at the message that turn began after;
    /// Codex can only fork a whole thread, so it is refused.
    private func fork(_ id: SessionId, from: SessionId, into project: ProjectId?, at: String) throws -> AgentChatSnapshot {
        guard let source = entries[from] else { throw ServiceError.unknownSession(from) }
        let project = project ?? source.snapshot.project
        if let entry = entries[id] {
            guard entry.snapshot.project == project else { throw ServiceError(.badRequest, "This agent session ID is already in use") }
            return entry.snapshot
        }
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        guard source.snapshot.provider == .claude else {
            throw ServiceError(.badRequest, "Codex can fork a conversation only at its latest message.")
        }
        guard let index = source.snapshot.items.firstIndex(where: { $0.id == at && $0.kind == .user && !$0.isProviderTurn }) else {
            throw ServiceError(.badRequest, "That message is not in this conversation.")
        }
        let first = !source.snapshot.items[..<index].contains { $0.kind == .user }
        let point = source.turnForkPoints[at]
        guard first || point != nil else {
            throw ServiceError(.badRequest, "This message predates fork points. Fork from the latest message instead.")
        }
        let folder = try projectDirectory(project)
        let directory = project == source.snapshot.project ? source.directory : folder
        try checkDirectory(directory)
        var snapshot = source.snapshot
        snapshot.session = id
        snapshot.project = project
        snapshot.revision = 0
        snapshot.status = .idle
        snapshot.turns = nil
        snapshot.subagents = nil
        snapshot.queuedPrompts = nil
        snapshot.queuePaused = nil
        snapshot.omittedItems = nil
        snapshot.contextUsage = nil
        snapshot.providerSession = point?.session
        snapshot.items = source.snapshot.items[..<index].filter { $0.kind != .approval || $0.isComplete }
        Self.finishItems(&snapshot.items)
        let entry = Entry(snapshot, directory: directory)
        entry.hasSuccessfulTurn = !first
        entry.forkSource = point?.session
        entry.forkPoint = point?.message
        entries[id] = entry
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    /// Provider conversations that open Tab conversations continue.
    func openProviderSessions() -> Set<String> {
        queue.sync {
            Set(entries.values.filter { $0.snapshot.status != .closed }.compactMap(\.snapshot.providerSession))
        }
    }

    /// Continues a conversation a provider CLI saved outside Tab; see `AgentHistoryImport`.
    /// `transcript` reads the saved conversation for the project's folder.
    func importHistory(_ request: AgentHistoryImport,
                       transcript: @escaping @Sendable (String) throws -> AgentHistoryTranscript) async throws -> AgentChatSnapshot {
        try request.validate()
        // One import into a conversation at a time: each stages its images in the same folders.
        if let existing = try queue.sync(execute: { () throws -> AgentChatSnapshot? in
            if let existing = try importTarget(request) { return existing }
            guard importing.insert(request.session).inserted else {
                throw ServiceError(.badRequest, "This conversation is already being continued")
            }
            return nil
        }) { return existing }
        defer { queue.sync { _ = importing.remove(request.session) } }
        let directory = try queue.sync { () throws -> String in
            let directory = try projectDirectory(request.project)
            try checkDirectory(directory)
            return directory
        }
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(request.session.description, isDirectory: true)
        var saved = try await runBlocking { try transcript(directory) }
        let items = Set(saved.items.map(\.id))
        let images = saved.images.filter { items.contains($0.key) }
        saved.images = [:]
        // The person's images are stored as their messages' attachments, as if sent here.
        let descriptors = try await written { () -> [String: [AgentChatAttachmentDescriptor]] in
            var descriptors: [String: [AgentChatAttachmentDescriptor]] = [:]
            for (item, images) in images where item.utf8.count <= 1024 {
                let folder = attachments.appendingPathComponent(AgentToolImages.directoryName(item: item), isDirectory: true)
                guard let staged = try? AgentAttachments.stageToolImages(images, root: folder) else { continue }
                try? AgentAttachments.record(staged, root: folder)
                descriptors[item] = staged.map(\.attachment.descriptor)
            }
            return descriptors
        }
        for index in saved.items.indices {
            if let attached = descriptors[saved.items[index].id] { saved.items[index].attachments = attached }
        }
        // Images staged for a conversation that isn't made go with it.
        let staged = descriptors.keys.map { attachments.appendingPathComponent(AgentToolImages.directoryName(item: $0), isDirectory: true) }
        let discardStaged = { [self] in write { for folder in staged { _ = Self.removeIfPresent(folder) } } }
        do {
            return try queue.sync { () throws -> AgentChatSnapshot in
                if let existing = try importTarget(request) {
                    discardStaged()
                    return existing
                }
                return commitImport(request, saved: saved, directory: directory)
            }
        } catch {
            discardStaged()
            throw error
        }
    }

    /// Makes the conversation an import continues, from what it read and staged.
    private func commitImport(_ request: AgentHistoryImport, saved: AgentHistoryTranscript, directory: String) -> AgentChatSnapshot {
        var snapshot = entries[request.session]?.snapshot
            ?? AgentChatSnapshot(session: request.session, project: request.project, provider: request.provider)
        snapshot.provider = request.provider
        snapshot.providerSession = request.providerSession
        snapshot.model = nil
        snapshot.reasoningEffort = nil
        snapshot.resolvedModel = saved.resolvedModel
        snapshot.contextUsage = nil
        snapshot.turns = AgentHistoryTranscript.turns(saved.items)
        snapshot.status = .idle
        snapshot.items = saved.items
        Self.finishItems(&snapshot.items)
        snapshot.items.append(AgentChatItem(kind: .notice,
            text: "Continued from \(request.provider.name). New messages carry on this conversation."))
        let entry = Entry(snapshot, directory: directory)
        entry.hasSuccessfulTurn = true
        entries[request.session] = entry
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    /// The conversation that already continues `request`'s, or `nil` when
    /// `request.session` is free to take it.
    private func importTarget(_ request: AgentHistoryImport) throws -> AgentChatSnapshot? {
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        if let existing = entries.values.first(where: {
            $0.snapshot.status != .closed && $0.snapshot.provider == request.provider
                && $0.snapshot.providerSession == request.providerSession
        }) {
            guard !existing.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
            return existing.snapshot
        }
        guard let entry = entries[request.session] else { return nil }
        guard !entry.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
        guard entry.snapshot.project == request.project, entry.snapshot.items.isEmpty, entry.snapshot.providerSession == nil,
              entry.snapshot.status == .idle, entry.runtime == nil, !entry.submitting, !entry.hasSuccessfulTurn else {
            throw ServiceError(.badRequest, "This agent session ID is already in use")
        }
        return nil
    }

    private func interrupted(_ entry: Entry, message: String) {

        entry.snapshot.status = .failed
        updateTurn(entry, status: .failed, outcome: .interrupted)
        entry.snapshot.revision &+= 1
        Self.finishItems(&entry.snapshot.items)
        entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
        bound(entry)
    }

    /// Ends a turn the user stopped by stopping its provider. The conversation stays
    /// usable: the next message resumes it in a new provider process.
    private func stopTurn(_ entry: Entry) {
        retireRuntime(entry, reason: "the response was stopped")
        entry.snapshot.status = .idle
        updateTurn(entry, status: .idle, outcome: .interrupted)
        Self.finishItems(&entry.snapshot.items)
        entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Agent interrupted."))
        touch(entry)
        persist(entry)
    }

    private func close(_ entry: Entry) {
        guard entry.snapshot.status != .closed else { return }
        entry.deliveryCancelled = true
        if !entry.inbox.visible.isEmpty {
            do {
                try mutateInbox(entry) { inbox in
                    inbox.paused = true
                    for index in inbox.records.indices { inbox.records[index].prompt = nil; inbox.records[index].display = nil }
                }
            } catch { entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Could not save queue cancellation: " + error.localizedDescription)) }
        }
        retireRuntime(entry)
        entry.snapshot.status = .closed
        updateTurn(entry, status: .closed, outcome: .cancelled)
        Self.finishItems(&entry.snapshot.items)
        touch(entry)
        persist(entry)
        settleSubmission(entry)
    }

    /// Save the archive and reset atomically before publishing the new context.
    private func clear(_ entry: Entry, archive id: SessionId, revision: UInt64, reply: Reply) throws {
        if entry.snapshot.resetID == id { reply.resume(returning: entry.snapshot); return }
        // Its copies of another conversation's checkpoints are known by its own name only.
        guard !entry.archived else { throw AgentRuntimeError("An archived conversation can't be cleared.") }
        // Whatever else changed, a revert admitted behind the clear's wait must finish first,
        // and an import into the conversation must be made or given up.
        guard entry.reverts == 0 else { throw AgentRuntimeError("A revert is being applied. Try again shortly.") }
        guard !importing.contains(entry.snapshot.session) else {
            throw AgentRuntimeError("A past conversation is being continued here. Try again shortly.")
        }
        guard !stopping, entry.snapshot.revision == revision, entries[id] == nil else {
            throw AgentRuntimeError("The conversation changed. Review it before clearing.")
        }
        guard !entry.submitting, entry.deliveryID == nil,
              entry.snapshot.status == .idle || entry.snapshot.status == .failed || entry.snapshot.status == .closed,
              entry.inbox.visible.isEmpty,
              entry.snapshot.subagents?.contains(where: { $0.status == .running }) != true else {
            throw AgentRuntimeError("Stop active work and remove queued prompts before clearing. Your conversation is kept.")
        }
        let session = entry.snapshot.session
        let oldEarlier = earlierFile(session: session)
        var archived = entry.snapshot
        archived.session = id; archived.status = .closed; archived.resetID = nil
        let saved = Saved(turnForkPoints: entry.turnForkPoints, snapshot: archived, directory: entry.directory,
            hasSuccessfulTurn: entry.hasSuccessfulTurn, forkSource: entry.forkSource, forkPoint: entry.forkPoint,
            lastProviderMessage: entry.lastProviderMessage, archived: true)
        var fresh = AgentChatSnapshot(session: session, project: archived.project, provider: archived.provider,
            model: archived.model, reasoningEffort: archived.reasoningEffort, accessMode: archived.accessMode,
            revision: archived.revision + 1)
        fresh.resetID = id; fresh.planMode = archived.planMode
        fresh.commands = archived.commands; fresh.commandDescriptors = archived.commandDescriptors
        let replacement = Saved(snapshot: fresh, directory: entry.directory, hasSuccessfulTurn: false)
        entry.resetting = true
        retireRuntime(entry)
        let next = fresh
        let previous = archived
        let current = entry.snapshot
        writer.async { [self] in
            do {
                // An earlier clear's leftover copies are its archive's: they must go before this
                // archive copies the folder and the conversation forgets the earlier one.
                guard recoverClearedCheckpoints(current).settled else {
                    throw AgentRuntimeError("This conversation's earlier archive can't be read yet, so it wasn't cleared. Try again later.")
                }
                // Copy before committing: a failed archive leaves the original readable.
                for folder in ["attachments", "outputs", "checkpoints"] {
                    let source = root.appendingPathComponent(folder + "/" + session.description)
                    let target = root.appendingPathComponent(folder + "/" + id.description)
                    try Self.copyAnew(source, to: target)
                }
                try Self.copyAnew(oldEarlier, to: root.appendingPathComponent("earlier/" + id.description + ".jsonl"))
                try JSONEncoder().encode(saved).write(to: root.appendingPathComponent(id.description + ".json"), options: .atomic)
                try JSONEncoder().encode(replacement).write(to: root.appendingPathComponent(session.description + ".json"), options: .atomic)
                retainedCheckpointIDs[id] = retainedCheckpointIDs[session]
                retainedCheckpointIDs[session] = []
                // The archive now owns these files and Git refs. Retiring the old
                // session's checkpoints later must not delete the archive's refs.
                let originals = ["attachments", "outputs", "checkpoints"].map { root.appendingPathComponent($0 + "/" + session.description) } + [oldEarlier]
                for original in originals where FileManager.default.fileExists(atPath: original.path) {
                    do { try FileManager.default.removeItem(at: original) }
                    catch { AgentLog.error("cleared conversation files could not be retired: \(error)") }
                }
                queue.async { [self] in
                    let replacement = Entry(next, directory: entry.directory)
                    // Keep delivery identities so delayed retries cannot replay old messages.
                    replacement.inbox = entry.inbox
                    let archive = Entry(previous, directory: entry.directory)
                    archive.archived = true
                    archive.turnForkPoints = entry.turnForkPoints
                    archive.forkSource = entry.forkSource; archive.forkPoint = entry.forkPoint
                    archive.lastProviderMessage = entry.lastProviderMessage
                    entries[id] = archive
                    entries[session] = replacement
                    notifyChanged(session, next.revision)
                    notifyActivity(next, entry.directory)
                    reply.resume(returning: next)
                }
            } catch {
                queue.async {
                    entry.resetting = false
                    reply.resume(throwing: error)
                }
            }
        }
    }

    /// The transcript keeps 16 KiB of a tool's output; a finished tool with more keeps the
    /// rest on disk, written by the persistence queue, so "Show full output" can read it.
    private func keepFullOutput(_ item: inout AgentChatItem, entry: Entry) {
        guard item.kind == .tool, item.isComplete,
              let originalOutput = item.tool?.output else { return }
        let input = item.tool?.input ?? ""
        let needsInput = input.utf8.count > 8 * 1024
        guard originalOutput.utf8.count > 16 * 1024 || needsInput else { return }
        let output = needsInput ? "Arguments\n" + input + "\n\nResult\n" + originalOutput : originalOutput
        let command = item.tool?.presentsCommand == true
        item.tool?.fullOutputBytes = output.utf8.count
        let file = outputFile(session: entry.snapshot.session, item: item.id)
        write {
            // A command's end matters most; any other tool's start.
            let bytes = Data(AgentReplyBounds.bounded(output, maximumBytes: AgentToolOutput.maximumBytes,
                maximumEncodedBytes: AgentToolOutput.maximumEncodedBytes, keepingEnd: command).text.utf8)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
            } catch { AgentLog.error("tool output not kept: \(error)") }
        }
    }

    /// Where items a conversation dropped past its size limit are kept, one JSON line each.
    private func earlierFile(session: SessionId) -> URL {
        let suffix = entries[session]?.snapshot.resetID.map { "-" + $0.description } ?? ""
        return root.appendingPathComponent("earlier", isDirectory: true).appendingPathComponent(session.description + suffix + ".jsonl")
    }

    /// The archive stops growing at this size; later drops are only counted.
    static let earlierArchiveBytes = 64 * 1024 * 1024

    private func archive(_ items: [AgentChatItem], session: SessionId) {
        let lines = items.compactMap { item -> Data? in
            // Each archived item is bounded like a retained one, so a page always fits a frame.
            guard let bounded = boundedItem(item, budget: 64 * 1024), var data = try? JSONEncoder().encode(bounded) else { return nil }
            data.append(0x0A)
            return data
        }
        guard !lines.isEmpty else { return }
        let file = earlierFile(session: session)
        write {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard size < UInt64(Self.earlierArchiveBytes) else { return }
                for line in lines { try handle.write(contentsOf: line) }
            } catch { AgentLog.error("agent earlier items not archived: \(error)") }
        }
    }

    /// A page of archived items, read on a blocking worker after earlier archive writes.
    private func earlierItems(session: SessionId, before: Int?, limit: Int) async throws -> AgentEarlierItems {
        let file = queue.sync { earlierFile(session: session) }
        let writer = writer
        return try await runBlocking { () throws -> AgentEarlierItems in
            writer.sync {}
            guard let data = try? Data(contentsOf: file) else { return AgentEarlierItems(items: [], start: 0, total: 0) }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            let end = min(before ?? lines.count, lines.count)
            var items: [AgentChatItem] = []
            var bytes = 0, encoded = 0
            var start = end
            while start > 0, items.count < limit {
                let line = lines[start - 1]
                guard let item = try? JSONDecoder().decode(AgentChatItem.self, from: Data(line)) else { start -= 1; continue }
                // Each line is its item as JSON, so it measures the reply's size too.
                guard bytes + item.transcriptByteCount <= AgentEarlierItems.maxBytes,
                      encoded + line.count <= AgentEarlierItems.maxEncodedBytes else { break }
                bytes += item.transcriptByteCount
                encoded += line.count
                items.insert(item, at: 0)
                start -= 1
            }
            return AgentEarlierItems(items: items, start: start, total: lines.count)
        }
    }

    private func outputFile(session: SessionId, item: String) -> URL {
        root.appendingPathComponent("outputs", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
            .appendingPathComponent(AgentToolImages.directoryName(item: item) + ".txt")
    }

    /// Stops the provider process. Agents it still runs stop with it; `reason` says why
    /// in the transcript when that is news to the user.
    private func retireRuntime(_ entry: Entry, reason: String? = nil) {
        let running = entry.snapshot.subagents?.filter { $0.status == .running }.count ?? 0
        if running > 0, let reason {
            entry.snapshot.items.append(AgentChatItem(kind: .notice, text: AgentRuntime.stoppedAgents(running, because: reason)))
        }
        entry.subagentSteps.removeAll()
        entry.pendingSubmission?.task?.cancel()
        entry.generation = UUID()
        let runtime = entry.runtime
        entry.runtime = nil
        entry.submitting = false
        entry.steering = false
        entry.approving.removeAll()
        entry.interrupting = nil
        entry.accessTask = nil
        // Its agents stop with its provider process.
        entry.snapshot.subagents = nil
        clearDeferredEvents(entry)
        retire(runtime, of: entry)
    }

    /// Stops a provider on a dispatch worker: stopping waits for the runtime's queue,
    /// which may be finishing a write to a provider that stopped reading, and must
    /// not hold one of Swift's cooperative threads meanwhile. It stays tracked until
    /// the provider has exited, so shutdown waits for it.
    private func retire(_ runtime: (any AgentSessionRuntime)?, of entry: Entry) {
        guard let runtime else { return }
        // Before a revert can look: from here it may finish a launch begun, but begins none.
        runtime.refuseLaunches()
        let token = UUID()
        retiring.withLock { $0[token] = runtime }
        DispatchQueue.global(qos: .utility).async { [retiring] in
            runtime.terminate()
            retiring.withLock { _ = $0.removeValue(forKey: token) }
        }
    }

    /// Runtimes stopping on a dispatch worker, until they have.
    private let retiring = OSAllocatedUnfairLock<[UUID: any AgentSessionRuntime]>(initialState: [:])

    private static let maximumDeferredEventBytes = 8 * AgentChatAttachment.maxPayloadBytes + 512 * 1024

    private func deferredBytes(_ event: AgentRuntimeEvent) -> Int {
        switch event {
        case .item(let item), .itemUpdate(let item): return item.transcriptByteCount
        case .toolItem(let item, let images):
            var bytes = min(item.transcriptByteCount, Self.maximumDeferredEventBytes + 1)
            for image in images {
                guard image.data.count <= Self.maximumDeferredEventBytes - min(bytes, Self.maximumDeferredEventBytes) else {
                    return Self.maximumDeferredEventBytes + 1
                }
                bytes += image.data.count
            }
            return bytes
        case .commandDescriptors(let descriptors): return descriptors.reduce(0) { $0 + $1.name.utf8.count + $1.description.utf8.count + ($1.argumentHint?.utf8.count ?? 0) }
        case .commands(let commands): return commands.reduce(0) { $0 + $1.utf8.count }
        case .subagentSteps(_, let items): return items.reduce(128) { $0 + $1.transcriptByteCount }
        case .textDelta(_, let text), .failure(let text), .providerSession(let text), .resolvedModel(let text): return text.utf8.count
        default: return 128
        }
    }

    private func clearDeferredEvents(_ entry: Entry) {
        entry.stagingToolImages = false
        entry.deferredEvents.removeAll()
        entry.deferredEventBytes = 0
        entry.deferredEventOverflow = false
    }

    @discardableResult
    private func configureAccess(_ entry: Entry, runtime: any AgentSessionRuntime,
                                 mode: AgentAccessMode) -> Task<Void, Error> {
        let previous = entry.accessTask
        let tools = entry.alwaysAllowedTools
        let task = Task {
            // Preserve accepted mode-change order even when concurrent request Tasks start out of order.
            _ = try? await previous?.value
            try await runtime.setAlwaysAllowed(tools)
            try await runtime.setAccess(mode)
        }
        entry.accessTask = task
        return task
    }

    private func settleSubmission(_ entry: Entry) {
        guard let pending = entry.pendingSubmission else { return }
        entry.pendingSubmission = nil
        guard !pending.finished else { return }
        pending.finished = true
        guard let delivery = pending.delivery else { return pending.continuation.resume(returning: entry.snapshot) }
        // A follow-up whose turn ended: never sent, or sent with no word back.
        if delivery.cancel() { return pending.continuation.resume(throwing: AgentDeliveryNotStarted()) }
        pending.continuation.resume(throwing: AgentRuntimeError("The response ended while this message was being handed over. Review the conversation before sending it again."))
    }

    /// Ends every item with its turn. A tool still running then never reported a
    /// result, so it was interrupted rather than left running forever.
    static func finishItems(_ items: inout [AgentChatItem]) {
        for index in items.indices {
            items[index].isComplete = true
            if items[index].tool?.status == .running || items[index].tool?.status == .queued {
                items[index].tool?.status = .interrupted
            }
        }
    }

    /// A tool's body travels once, in `tool`. Providers also put it in `detail` for older
    /// clients, which counted it twice against the transcript budget; every reader of a
    /// tool item falls back to `detail` only when `tool` has nothing.
    static func dropDuplicateDetail(_ item: inout AgentChatItem) {
        guard item.kind == .tool, let tool = item.tool, let detail = item.detail, !detail.isEmpty else { return }
        let exit = tool.exitCode.map { "\nExit code: \($0)" } ?? ""
        if detail == tool.output || detail == tool.input || detail == (tool.output ?? "") + exit { item.detail = nil }
    }

    private func observedItem(_ value: AgentChatItem, entry: Entry, previous: AgentChatItem? = nil) -> AgentChatItem {
        if previous?.tool?.isApplicationTool == true, value.tool?.isApplicationTool != true, let previous { return previous }
        var item = value
        item.attachments = item.attachments ?? previous?.attachments
        Self.dropDuplicateDetail(&item)
        item.questionnaire = item.questionnaire ?? previous?.questionnaire
        let now = Date()
        item.createdAt = item.createdAt ?? previous?.createdAt ?? item.tool?.startedAt ?? now
        item.updatedAt = item.updatedAt ?? now
        var context = item.workContext ?? previous?.workContext ?? AgentChatWorkContext()
        context.runID = context.runID ?? previous?.workContext?.runID
            ?? (item.kind == .user ? "native-turn:" + item.id : entry.snapshot.turns?.last.map { "native-turn:" + $0.userItemID })
        if context.itemType == nil {
            switch item.kind {
            case .user: context.itemType = "user_message"
            case .assistant: context.itemType = "assistant_message"
            case .approval: context.itemType = "approval_request"
            case .notice: context.itemType = "system_notice"
            case .tool:
                if item.tool?.presentsCommand == true { context.itemType = "command_execution" }
                else {
                    switch item.tool?.presentation {
                    case .fileChange: context.itemType = "file_change"
                    case .fileSearch: context.itemType = "file_search"
                    case .webSearch: context.itemType = "web_search"
                    default: context.itemType = "dynamic_tool"
                    }
                }
            }
        }
        item.workContext = context
        return item
    }

    private func updateTurn(_ entry: Entry, status: AgentChatStatus, outcome: AgentChatTurn.Outcome? = nil) {
        guard var turns = entry.snapshot.turns, let index = turns.indices.last,
              turns[index].completedAt == nil else { return }
        let now = Date()
        turns[index].observe(status, at: now)
        if status == .idle || status == .failed || status == .closed {
            turns[index].completedAt = max(now, turns[index].startedAt)
            turns[index].outcome = outcome
            captureCompletedTurn(entry, turnID: turns[index].userItemID)
        }
        entry.snapshot.turns = turns
    }

    /// Startup recovery is idempotent: a final record can precede its transcript
    /// revision on disk, and a persisted baseline can outlive an interrupted run.
    private func restoreCheckpoints(_ entry: Entry) {
        let directory = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
        guard var turns = entry.snapshot.turns else { return }
        var pending: AgentCheckpointPending?
        for index in turns.indices where turns[index].checkpoint == nil {
            let id = turns[index].userItemID
            guard UUID(uuidString: id) != nil else { continue }
            if let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
               let record = try? JSONDecoder().decode(AgentCheckpointRecord.self, from: data) {
                turns[index].checkpoint = record.summary(id: id)
            } else if index == turns.indices.last,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("pending-" + id + ".json")),
                      let value = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data),
                      value.turnID == id, value.before.directory == entry.directory {
                pending = value
            }
        }
        entry.snapshot.turns = turns
        if let pending {
            entry.baseline = CheckpointBaseline(pending.before)
            // Already-terminal turns do not pass through updateTurn on startup.
            if turns.last?.completedAt != nil { captureCompletedTurn(entry, turnID: pending.turnID) }
        }
    }

    private func captureCompletedTurn(_ entry: Entry, turnID: String) {
        guard let baseline = entry.baseline else { return }
        entry.baseline = nil
        let directory = entry.directory
        let destination = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
        storeWork.enter()
        let store = checkpointStore
        let checkpointsRoot = root.appendingPathComponent("checkpoints", isDirectory: true)
        // After this turn's baseline on the same queue, which has taken it by then.
        entry.checkpoints.async { [weak self, storeWork] in
            defer { storeWork.leave() }
            guard let before = baseline.taken else { return }
            do {
                let after: AgentCheckpointStore.Snapshot
                do { after = try store.capture(directory: directory) } catch {
                    Self.keepUnsettled(error, in: checkpointsRoot)
                    throw error
                }
                let summary: AgentTurnCheckpoint
                do {
                    let files = try store.files(from: before, to: after)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    // A baseline recovered from an older record finds its repository through this one.
                    var before = before
                    if before.repository == nil, before.directory == after.directory { before.repository = after.repository }
                    let record = AgentCheckpointRecord(before: before, after: after, files: files)
                    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(turnID + ".json"), options: .atomic)
                    summary = record.summary(id: turnID)
                } catch {
                    Self.discard(after, store: store, in: checkpointsRoot)
                    throw error
                }
                self?.queue.async { [weak self] in
                    guard let self, !self.stopping, !entry.resetting, self.entries[entry.snapshot.session] === entry,
                          let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turnID }) else { return }
                    entry.snapshot.turns?[index].checkpoint = summary
                    self.touch(entry)
                    self.persist(entry)
                }
            } catch {
                // Keep the durable baseline pinned so restart recovery can retry.
                AgentLog.error("agent checkpoint unavailable: \(error)")
            }
        }
    }

    /// Called before removing a project/worktree, including conversations never attached to a client.
    func close(project: ProjectId, directory: String? = nil) {
        queue.sync {
            guard !stopping else { return }
            for entry in entries.values {
                let inside = directory.map { AgentPaths.isInside(entry.directory, $0) } ?? false
                if entry.snapshot.project == project || inside { close(entry) }
            }
        }
    }

    func shutdown() {
        let runtimes: [any AgentSessionRuntime] = queue.sync {
            stopping = true
            var runtimes: [any AgentSessionRuntime] = []
            for entry in entries.values {
                entry.pendingSubmission?.task?.cancel()
                entry.generation = UUID()
                if let runtime = entry.runtime { runtimes.append(runtime) }
                entry.runtime = nil
                if entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                    interrupted(entry, message: "Agent interrupted when the server stopped. Send a message to resume.")
                }
                entry.submitting = false
                entry.approving.removeAll()
                entry.interrupting = nil
                entry.accessTask = nil
                clearDeferredEvents(entry)
                persist(entry)
                settleSubmission(entry)
            }
            return runtimes
        }
        // Each waits for its own provider to exit, so stop them together, with the
        // ones still retiring: the host may exit as soon as this returns.
        let stopping = runtimes + retiring.withLock { Array($0.values) }
        DispatchQueue.concurrentPerform(iterations: stopping.count) { stopping[$0].terminate() }
        if let checkpointDrain, storeWork.wait(timeout: .now() + checkpointDrain) == .timedOut {
            AgentLog.error("checkpoints were still being taken when shutdown returned")
            writer.sync {}
            drainCallbacks()
            return
        }
        storeWork.wait()
        writer.sync {}
        fence.close()
        drainCallbacks()
    }

    func refuseNewRequests() { queue.sync { stopping = true } }

    /// Once no checkpoint is being taken or revert applied, and what they saved is written,
    /// writes nothing more and runs `body`, which hands the store to its next owner: at
    /// once if none is.
    func releaseStore(then body: @escaping @Sendable () -> Void) {
        if storeWork.wait(timeout: .now()) == .success {
            writer.sync {}
            fence.close()
            return body()
        }
        storeWork.notify(queue: .global(qos: .utility)) { [self] in
            writer.sync {}
            fence.close()
            body()
        }
    }

    /// Atomically checks ownership and reserves the store for an idle shutdown.
    /// A create either wins first and makes this fail, or observes the refusal.
    func tryRefuseIfIdle() -> Bool {
        queue.sync {
            guard !stopping,
                  !entries.values.contains(where: { $0.snapshot.status != .closed || $0.runtime != nil || $0.submitting }) else {
                return false
            }
            stopping = true
            return true
        }
    }

    private func touch(_ entry: Entry) {
        guard !entry.resetting, entries[entry.snapshot.session] === entry else { return }
        notifyActivity(entry.snapshot, entry.directory)
        bound(entry)
        entry.snapshot.revision &+= 1
        recordItemRevisions(entry)
        if !entry.notifying {
            entry.notifying = true
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                entry.notifying = false
                guard !stopping, !entry.resetting, entries[entry.snapshot.session] === entry else { return }
                notifyChanged(entry.snapshot.session, entry.snapshot.revision)
            }
        }
        if !entry.checkpointing {
            entry.checkpointing = true
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                entry.checkpointing = false
                guard !stopping else { return }
                persist(entry)
            }
        }
    }

    /// Stamps each item that differs from the last revision with the current one. Items
    /// that didn't change share storage with their last copy, so comparing them is cheap.
    private func recordItemRevisions(_ entry: Entry) {
        var observed: [String: AgentChatItem] = [:]
        observed.reserveCapacity(entry.snapshot.items.count)
        for item in entry.snapshot.items {
            if entry.observedItems[item.id] != item { entry.itemRevisions[item.id] = entry.snapshot.revision }
            observed[item.id] = item
        }
        entry.observedItems = observed
        if entry.itemRevisions.count > observed.count * 2 + 64 {
            entry.itemRevisions = entry.itemRevisions.filter { observed[$0.key] != nil }
        }
    }

    /// The conversation relative to `revision`: everything when the client's revision isn't
    /// one this server can answer for, else only the items changed after it.
    private func delta(_ entry: Entry, since revision: UInt64) -> AgentChatDelta {
        var snapshot = entry.snapshot
        let ids = snapshot.items.map(\.id)
        if revision < snapshot.revision {
            snapshot.items = snapshot.items.filter { (entry.itemRevisions[$0.id] ?? .max) > revision }
            return AgentChatDelta(snapshot: snapshot, since: revision, itemIDs: ids)
        }
        // Equal: nothing changed. Newer than the server: a full answer the client can't apply.
        if revision == snapshot.revision { snapshot.items = [] }
        return AgentChatDelta(snapshot: snapshot, since: revision, itemIDs: ids)
    }

    private func bound(_ entry: Entry) {
        // Even worst-case six-byte JSON escapes for all 512 KiB of bodies and
        // 512 x 1 KiB IDs stay comfortably below the 16 MiB control-frame limit.
        entry.snapshot.items.removeAll { $0.id.utf8.count > 1024 }
        if let id = entry.snapshot.providerSession, id.utf8.count > 4096 { entry.snapshot.providerSession = nil }
        if let model = entry.snapshot.model, model.utf8.count > 256 { entry.snapshot.model = nil }
        if let model = entry.snapshot.resolvedModel, model.utf8.count > 256 { entry.snapshot.resolvedModel = nil }
        if let usage = entry.snapshot.contextUsage,
           usage.usedTokens < 0 || (usage.contextWindow.map({ $0 <= 0 }) ?? false) {
            entry.snapshot.contextUsage = nil
        }
        if entry.snapshot.items.filter({ $0.kind == .approval && !$0.isComplete }).count > 128 {
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed, outcome: .failed)
            Self.finishItems(&entry.snapshot.items)
        }
        // Retain pending permission IDs even when later tool/output rows overflow.
        // At most 128 are admitted; reserve up to 256 KiB for their display text.
        let pending = entry.snapshot.items.indices.filter {
            entry.snapshot.items[$0].kind == .approval && !entry.snapshot.items[$0].isComplete
        }
        let latestUser = entry.snapshot.items.indices.last { entry.snapshot.items[$0].kind == .user }
        let priority = pending + (latestUser.map { [$0] } ?? [])
        let prioritySet = Set(priority)
        let countBefore = entry.snapshot.items.count
        let original = entry.snapshot.items
        let recent = entry.snapshot.items.indices.filter { !prioritySet.contains($0) }.suffix(512 - priority.count)
        entry.snapshot.items = (priority + recent).sorted().map { entry.snapshot.items[$0] }
        let userID = entry.snapshot.items.last { $0.kind == .user }?.id
        var remaining = 512 * 1024
        var preserved: Set<String> = []
        for index in entry.snapshot.items.indices {
            let item = entry.snapshot.items[index]
            let pending = item.kind == .approval && !item.isComplete
            guard pending || item.id == userID else { continue }
            if let bounded = boundedItem(item, budget: pending ? min(remaining, max(2048, (item.questionnaire?.transcriptByteCount ?? 0) + 1024)) : min(64 * 1024, remaining), pending: pending) {
                entry.snapshot.items[index] = bounded
                remaining -= bounded.transcriptByteCount
                preserved.insert(item.id)
            }
        }
        var remove: [Int] = []
        for index in entry.snapshot.items.indices.reversed() {
            let item = entry.snapshot.items[index]
            if preserved.contains(item.id) { continue }
            guard let bounded = boundedItem(item, budget: remaining) else { remove.append(index); continue }
            entry.snapshot.items[index] = bounded
            remaining -= bounded.transcriptByteCount
        }
        for index in remove { entry.snapshot.items.remove(at: index) }
        // Removed items are counted, so clients can say the conversation's start is gone,
        // and archived, so they can page back to it.
        let dropped = countBefore - entry.snapshot.items.count
        if dropped > 0 {
            entry.snapshot.omittedItems = (entry.snapshot.omittedItems ?? 0) + dropped
            let kept = Set(entry.snapshot.items.map(\.id))
            archive(original.filter { !kept.contains($0.id) }, session: entry.snapshot.session)
        }
        if let turns = entry.snapshot.turns {
            let users = Set(entry.snapshot.items.filter { $0.kind == .user }.map(\.id))
            var retained = Array(turns.filter { users.contains($0.userItemID) }.suffix(512))
            var checkpointBudget = 64 * 1024
            for index in retained.indices.reversed() {
                guard var checkpoint = retained[index].checkpoint else { continue }
                let bytes = checkpoint.files.reduce(0) { $0 + $1.path.utf8.count + 64 }
                if bytes > checkpointBudget {
                    checkpoint.files = []
                    checkpoint.truncated = checkpoint.totalFiles > 0
                } else { checkpointBudget -= bytes }
                retained[index].checkpoint = checkpoint
            }
            entry.snapshot.turns = retained
        }
    }

    private func boundedItem(_ source: AgentChatItem, budget: Int, pending: Bool = false) -> AgentChatItem? {
        guard budget > 0 else { return nil }
        var item = source
        var remaining = budget
        // Reserve all non-body fields before clipping compatibility text/tool data.
        // The same accounting as validation includes observed dates and work IDs.
        remaining -= item.transcriptByteCount - item.text.utf8.count
            - (item.detail?.utf8.count ?? 0) - (item.tool?.transcriptByteCount ?? 0)
        guard remaining >= 0 else { return nil }
        if let tool = item.tool {
            item.tool = boundedTool(tool, budget: min(32 * 1024, max(0, remaining - 1024)))
            if item.tool == nil {
                guard pending else { return nil }
                item.detail = "[Tool metadata truncated]\n" + (item.detail ?? "")
            }
            remaining -= item.tool?.transcriptByteCount ?? 0
        }
        let detailReserve = min(truncationMarker.utf8.count, item.detail?.utf8.count ?? 0)
        let textBudget = min(pending ? 512 : 64 * 1024, max(0, remaining - detailReserve))
        if textBudget < truncationMarker.utf8.count, item.text.utf8.count > textBudget { return nil }
        item.text = clipped(item.text, bytes: textBudget)
        remaining -= item.text.utf8.count
        if let detail = item.detail { item.detail = clipped(detail, bytes: min(pending ? 1536 : 16 * 1024, max(0, remaining))) }
        return item.transcriptByteCount <= budget ? item : nil
    }

    private func boundedTool(_ source: AgentToolActivity, budget: Int) -> AgentToolActivity? {
        let note = "\n[Tool metadata truncated]"
        guard budget >= 512 + note.utf8.count else { return nil }
        if source.transcriptByteCount <= budget,
           (source.name?.utf8.count ?? 0) <= 256,
           (source.input?.utf8.count ?? 0) <= 8 * 1024,
           (source.output?.utf8.count ?? 0) <= 16 * 1024,
           (source.filePaths?.count ?? 0) <= 32, (source.urls?.count ?? 0) <= 32,
           (source.fileChanges?.count ?? 0) <= 32,
           (source.filePaths ?? []).allSatisfy({ $0.utf8.count <= 1024 }),
           (source.urls ?? []).allSatisfy({ $0.utf8.count <= 2048 }),
           (source.fileChanges ?? []).allSatisfy({ $0.path.utf8.count <= 1024
               && ($0.diff?.utf8.count ?? 0) <= 8 * 1024 && ($0.kind?.utf8.count ?? 0) <= 64 }) {
            return source
        }
        var tool = source
        var remaining = budget - 512 - note.utf8.count
        var truncated = source.output?.hasSuffix(note) == true
        func take(_ text: String?, limit: Int) -> String? {
            guard let text else { return nil }
            let bytes = min(limit, remaining)
            if text.utf8.count > bytes { truncated = true }
            guard bytes >= truncationMarker.utf8.count || text.utf8.count <= bytes else { return nil }
            let value = clipped(text, bytes: bytes)
            remaining -= value.utf8.count
            return value
        }
        // A diff keeps its start, cut at a line, so its first hunk header survives.
        func takeDiff(_ text: String?, limit: Int) -> String? {
            guard let text else { return nil }
            let bytes = min(limit, remaining)
            if text.utf8.count > bytes { truncated = true }
            let value = Self.clippedDiff(text, bytes: bytes)
            remaining -= value.utf8.count
            return value
        }
        func strings(_ values: [String]?, limit: Int) -> [String]? {
            guard let values else { return nil }
            if values.count > 32 { truncated = true }
            var result: [String] = []
            for value in values.prefix(32) {
                guard remaining >= 8 else { truncated = true; break }
                remaining -= 8
                guard let text = take(value, limit: limit) else { remaining += 8; break }
                result.append(text)
            }
            return result
        }
        tool.name = take(source.name, limit: 256)
        tool.input = take(source.input, limit: 8 * 1024)
        let output = source.output.map { $0.hasSuffix(note) ? String($0.dropLast(note.count)) : $0 }
        if source.presentsCommand {
            tool.output = take(output, limit: 16 * 1024 - note.utf8.count)
        } else if let output {
            // A file read or search result is read from its start.
            let bytes = min(16 * 1024 - note.utf8.count, remaining)
            if output.utf8.count > bytes { truncated = true }
            tool.output = Self.utf8Prefix(output, bytes: max(0, bytes))
            remaining -= tool.output?.utf8.count ?? 0
        }
        tool.filePaths = strings(source.filePaths, limit: 1024)
        tool.urls = strings(source.urls, limit: 2048)
        if let changes = source.fileChanges {
            if changes.count > 32 { truncated = true }
            var result: [AgentToolActivity.FileChange] = []
            for change in changes.prefix(32) {
                guard remaining >= 64 else { truncated = true; break }
                remaining -= 64
                guard let path = take(change.path, limit: 1024) else { remaining += 64; break }
                result.append(.init(path: path, diff: takeDiff(change.diff, limit: 8 * 1024), kind: take(change.kind, limit: 64)))
            }
            tool.fileChanges = result
        }
        func reserve(_ bytes: Int) -> Bool {
            guard remaining >= bytes else { truncated = true; return false }
            remaining -= bytes
            return true
        }
        tool.searchPatterns = strings(source.searchPatterns, limit: 2048)
        if let results = source.webResults {
            if results.count > 32 { truncated = true }
            tool.webResults = results.prefix(32).compactMap { result in
                guard reserve(64) else { return nil }
                return .init(title: take(result.title, limit: 1024), url: take(result.url, limit: 2048),
                             snippet: take(result.snippet, limit: 8000))
            }
        }
        tool.fileSearchDetails = nil
        if let details = source.fileSearchDetails, reserve(64) {
            var bounded = AgentToolActivity.FileSearchDetails(pattern: take(details.pattern, limit: 2048))
            if let results = details.results {
                if results.count > 32 { truncated = true }
                bounded.results = results.prefix(32).compactMap { result in
                    guard reserve(128), let name = take(result.fileName, limit: 1024), !name.isEmpty else { return nil }
                    return .init(fileName: name, line: result.line, column: result.column,
                                 preview: take(result.preview, limit: 8000))
                }
            }
            tool.fileSearchDetails = bounded
        }
        tool.fileChangeDetails = nil
        if let details = source.fileChangeDetails, reserve(128),
           let name = take(details.fileName, limit: 1024), !name.isEmpty {
            var bounded = AgentToolActivity.FileChangeDetails(fileName: name, diff: takeDiff(details.diff, limit: 8 * 1024),
                                                               additions: details.additions, deletions: details.deletions)
            if let operations = details.operations {
                if operations.count > 32 { truncated = true }
                bounded.operations = operations.prefix(32).compactMap { operation in
                    guard reserve(128), let kind = take(operation.operation, limit: 64),
                          let path = take(operation.path, limit: 1024), !path.isEmpty else { return nil }
                    return .init(operation: kind, path: path, oldPath: take(operation.oldPath, limit: 1024),
                                 fileType: take(operation.fileType, limit: 128), mimeType: take(operation.mimeType, limit: 128))
                }
            }
            tool.fileChangeDetails = bounded
        }
        if truncated { tool.output = (tool.output ?? "") + note }
        return tool
    }

    private let truncationMarker = "[Earlier text truncated]\n"

    /// The end of a diff the transcript dropped; clients mark the diff truncated.
    static let diffTruncationMarker = AgentToolActivity.diffTruncationMarker

    /// `text` within `bytes`, keeping whole lines from its start and saying where it stops.
    static func clippedDiff(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let marker = "\n" + diffTruncationMarker
        guard bytes > marker.utf8.count else { return "" }
        let head = utf8Prefix(text, bytes: bytes - marker.utf8.count)
        let line = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        return line + marker
    }

    /// The longest start of `text` within `bytes` that ends between characters.
    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, bytes))
        while end > text.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    private func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        guard bytes >= truncationMarker.utf8.count else { return "" }
        // Drop a partial leading scalar instead of introducing a replacement character.
        var suffix = text.utf8.suffix(bytes - truncationMarker.utf8.count)
        while let first = suffix.first, first & 0xC0 == 0x80 { suffix = suffix.dropFirst() }
        return truncationMarker + String(decoding: suffix, as: UTF8.self)
    }

    /// Whole tool outputs go with their items: trimmed away, or the conversation closed.
    private func cleanupOutputs(_ saved: Saved) {
        let directory = root.appendingPathComponent("outputs", isDirectory: true)
            .appendingPathComponent(saved.snapshot.session.description, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let kept = saved.snapshot.status == .closed && saved.archived != true ? [] : Set(saved.snapshot.items.lazy
            .filter { $0.tool?.fullOutputBytes != nil }.map { AgentToolImages.directoryName(item: $0.id) + ".txt" })
        for file in files where !kept.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    /// How long a closed conversation is kept after it last changed.
    static let closedRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Records of conversations being deleted. A record moves here before anything kept
    /// for it goes, so it never loads beside missing files, and stays until all of it is
    /// gone, so a deletion cut short finishes at the next start.
    private var removing: URL { root.appendingPathComponent("removing", isDirectory: true) }

    /// Deletes a conversation's file and everything kept beside it: checkpoints and their
    /// refs, tool outputs, attachments, archived items and its prompt inbox.
    private func removeConversation(_ saved: Saved, file: URL) {
        let record = removing.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: removing, withIntermediateDirectories: true)
            guard rename(file.path, record.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            AgentLog.error("expired conversation kept: \(file.lastPathComponent): \(error)")
            return
        }
        finishRemoving(saved.snapshot, record: record)
    }

    /// Removes what was kept for a conversation whose record is in `removing`, then the
    /// record, which stays while anything remains so the next start tries again. Records
    /// an interrupted clear left beside the archive's copies are the archive's, refs too.
    private func finishRemoving(_ snapshot: AgentChatSnapshot, record: URL) {
        let session = snapshot.session.description
        let cleared = recoverClearedCheckpoints(snapshot)
        let checkpoints = root.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent(session, isDirectory: true)
        let store = checkpointStore
        // Records whose owner can't be told yet keep their refs, and the deletion waits.
        var pinned = cleared.unknown.count + (cleared.unreadable ? 1 : 0)
        for checkpoint in (try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)) ?? []
            where checkpoint.pathExtension == "json" {
            let name = checkpoint.deletingPathExtension().lastPathComponent
            guard !cleared.claims(name) else { continue }
            guard let data = try? Data(contentsOf: checkpoint),
                  let refs = try? JSONDecoder().decode(CheckpointPins.self, from: data).refs else {
                pinned += 1
                AgentLog.error("checkpoint of a deleted conversation kept: \(checkpoint.lastPathComponent) can't be read")
                continue
            }
            // Each ref on its own, so one Git can't remove yet doesn't keep the other.
            let failures = refs.compactMap { ref -> Error? in
                do { try store.remove(ref); return nil } catch { return error }
            }
            if let failure = failures.first {
                pinned += 1
                AgentLog.error("checkpoint of a deleted conversation kept for later: \(checkpoint.lastPathComponent): \(failure)")
            } else {
                _ = Self.removeIfPresent(checkpoint)
            }
        }
        let others = [root.appendingPathComponent("outputs", isDirectory: true).appendingPathComponent(session, isDirectory: true),
                      root.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(session, isDirectory: true),
                      root.appendingPathComponent("earlier/" + session + (snapshot.resetID.map { "-" + $0.description } ?? "") + ".jsonl"),
                      root.appendingPathComponent("inbox/" + session + ".json")]
        // A checkpoint whose ref remains keeps its record, and so its folder.
        let remaining = (pinned > 0 ? others : [checkpoints] + others).filter { !Self.removeIfPresent($0) }.count + (pinned > 0 ? 1 : 0)
        guard remaining == 0 else {
            AgentLog.error("deleting conversation \(session) continues at the next start: \(remaining) of its files remain")
            return
        }
        _ = Self.removeIfPresent(record)
    }

    /// Removes `url`; true once it is gone for certain, not merely out of sight, as behind
    /// a folder this process can't search.
    private static func removeIfPresent(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            var status = stat()
            return lstat(url.path, &status) != 0 && (errno == ENOENT || errno == ENOTDIR)
        }
    }

    /// Finishes deletions a previous run started. Called before this run expires anything,
    /// so the writer settles each of them before it deletes again; whether its conversation
    /// came back is decided there too, as the store is then.
    private func resumeRemovals() {
        for record in (try? FileManager.default.contentsOfDirectory(at: removing, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            where record.pathExtension == "json" {
            let size = (try? record.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= AgentLimits.maxFrame,
                  let data = try? Data(contentsOf: record), let saved = try? JSONDecoder().decode(Saved.self, from: data),
                  record.deletingPathExtension().lastPathComponent == saved.snapshot.session.description else {
                AgentLog.error("unreadable record of a deleted conversation kept: \(record.lastPathComponent)")
                continue
            }
            let restored = root.appendingPathComponent(record.lastPathComponent)
            writer.async {
                // A conversation whose record came back keeps its files; deleting it again
                // starts over from that record.
                if FileManager.default.fileExists(atPath: restored.path) { _ = Self.removeIfPresent(record) }
                else { self.finishRemoving(saved.snapshot, record: record) }
            }
        }
    }

    /// The refs a checkpoint record or pending baseline pins, read apart from the rest of it.
    private struct CheckpointPins: Decodable {
        var before: AgentCheckpointStore.Snapshot
        var after: AgentCheckpointStore.Snapshot?
        var refs: [AgentCheckpointStore.Snapshot] { [before] + (after.map { [$0] } ?? []) }
        func same(as other: CheckpointPins) -> Bool { refs.map(\.reference) == other.refs.map(\.reference) }
    }

    /// Whose the records in a cleared conversation's checkpoints folder are, after a clear
    /// that stopped before it retired the copies its archive took.
    private struct ClearedCheckpoints {
        /// Checkpoints whose records pin a ref the archive's records pin: theirs.
        var archived: Set<String> = []
        /// Checkpoints whose owner can't be told yet, as while the archive can't be read:
        /// nothing may unpin their refs.
        var unknown: Set<String> = []
        /// Archived checkpoints whose copies couldn't be taken out of the folder.
        var leftover: Set<String> = []
        /// The folder couldn't be listed, so nothing in it can be told apart.
        var unreadable = false
        var settled: Bool { unknown.isEmpty && leftover.isEmpty && !unreadable }

        /// Whether the record named `name` isn't the conversation's own to unpin.
        func claims(_ name: String) -> Bool {
            let id = AgentSessions.checkpointID(name)
            return archived.contains(id) || unknown.contains(id)
        }
    }

    /// The turn a checkpoint record or pending baseline file belongs to.
    static func checkpointID(_ name: String) -> String { name.hasPrefix("pending-") ? String(name.dropFirst(8)) : name }

    /// Recover ownership if clear committed before removing duplicate checkpoint files: a
    /// record pinning any ref the archive's records pin is the archive's copy, in whatever
    /// form the archive has kept it since, and is taken out.
    private func recoverClearedCheckpoints(_ snapshot: AgentChatSnapshot) -> ClearedCheckpoints {
        var result = ClearedCheckpoints()
        guard let archive = snapshot.resetID else { return result }
        let archived = root.appendingPathComponent("checkpoints/" + archive.description)
        let current = root.appendingPathComponent("checkpoints/" + snapshot.session.description)
        let decoder = JSONDecoder()
        let records: [URL]
        do { records = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" } }
        catch { result.unreadable = (try? Self.isPresent(current)) != false; return result }
        var pinned = Set<String>(), complete = true
        do {
            for file in try FileManager.default.contentsOfDirectory(at: archived, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let pins = try? decoder.decode(CheckpointPins.self, from: data) else {
                    complete = false
                    continue
                }
                pinned.formUnion(pins.refs.map(\.reference))
            }
        } catch {
            complete = (try? Self.isPresent(archived)) == false
        }
        for file in records {
            let id = Self.checkpointID(file.deletingPathExtension().lastPathComponent)
            guard let data = try? Data(contentsOf: file), let pins = try? decoder.decode(CheckpointPins.self, from: data) else {
                result.unknown.insert(id)
                continue
            }
            if pins.refs.contains(where: { pinned.contains($0.reference) }) {
                result.archived.insert(id)
                if !Self.removeIfPresent(file) { result.leftover.insert(id) }
            } else if !complete {
                result.unknown.insert(id)
            }
        }
        return result
    }

    /// Refs a capture made, or may have, that no checkpoint uses: kept here until they are
    /// known to be gone.
    private static func unsettledFolder(_ checkpoints: URL) -> URL { checkpoints.appendingPathComponent(".unsettled", isDirectory: true) }

    /// Keeps `snapshot`'s ref, which no checkpoint uses, for removal when the store next opens.
    private static func removeLater(_ snapshot: AgentCheckpointStore.Snapshot, in checkpoints: URL) {
        let folder = unsettledFolder(checkpoints)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch { AgentLog.error("checkpoint ref \(snapshot.reference) may stay pinned: \(error)") }
    }

    /// Keeps the ref a failed capture may have made, for removal when the store next opens.
    static func keepUnsettled(_ error: Error, in checkpoints: URL) {
        guard let unsettled = error as? AgentCheckpointStore.UnsettledPin else { return }
        removeLater(unsettled.snapshot, in: checkpoints)
    }

    /// Removes the ref of a snapshot no checkpoint uses, or keeps it for the next start.
    static func discard(_ snapshot: AgentCheckpointStore.Snapshot, store: AgentCheckpointStore, in checkpoints: URL) {
        do { try store.remove(snapshot) } catch { removeLater(snapshot, in: checkpoints) }
    }

    /// Removes the refs captures left unsettled, keeping any Git still can't account for.
    private func settleUnsettledPins() {
        let folder = Self.unsettledFolder(root.appendingPathComponent("checkpoints", isDirectory: true))
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(AgentCheckpointStore.Snapshot.self, from: data) else { continue }
            do {
                try checkpointStore.remove(snapshot)
                _ = Self.removeIfPresent(file)
            } catch { AgentLog.error("checkpoint ref \(snapshot.reference) kept for later: \(error)") }
        }
    }

    /// Copies a clear stopped while making: the archive they were for never committed.
    private func reclaimAbandonedCopies() {
        for folder in ["attachments", "outputs", "checkpoints", "earlier"] {
            let parent = root.appendingPathComponent(folder, isDirectory: true)
            for entry in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                where entry.lastPathComponent.hasPrefix(".copying-") {
                _ = Self.removeIfPresent(entry)
            }
        }
    }

    /// Copies `source`, when there is one, to `target` whole: an earlier attempt's copy is
    /// replaced, since the clear it was for never committed, and a copy cut short never
    /// takes the target's name.
    private static func copyAnew(_ source: URL, to target: URL) throws {
        if try isPresent(target) { try FileManager.default.removeItem(at: target) }
        guard try isPresent(source) else { return }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".copying-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.moveItem(at: staging, to: target)
    }

    /// Whether `url` is there; throws when that can't be told, as behind a folder this
    /// process can't search.
    static func isPresent(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static let repositoryKey = Data("\"repository\"".utf8)

    private static func occurrences(of needle: Data, in data: Data) -> Int {
        var count = 0, start = data.startIndex
        while let found = data.range(of: needle, in: start..<data.endIndex) { count += 1; start = found.upperBound }
        return count
    }

    /// Records from before snapshots kept their repository get it while their folder still
    /// leads there, so their refs are found after the folder is gone, as a removed worktree.
    private func recordRepositories() {
        let checkpoints = root.appendingPathComponent("checkpoints", isDirectory: true)
        let git = GitCommand()
        var repositories: [String: String?] = [:]
        for folder in (try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)) ?? []
            where !folder.lastPathComponent.hasPrefix(".") {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "json" {
                // Upgraded records name a repository for each snapshot: a pending baseline one, a record two.
                let snapshots = file.lastPathComponent.hasPrefix("pending-") ? 1 : 2
                guard let data = try? Data(contentsOf: file), !data.isEmpty,
                      Self.occurrences(of: Self.repositoryKey, in: data) < snapshots,
                      var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                var changed = false
                for key in ["before", "after"] {
                    guard var snapshot = record[key] as? [String: Any], snapshot["repository"] == nil,
                          let directory = snapshot["directory"] as? String else { continue }
                    if repositories[directory] == nil {
                        repositories[directory] = FileManager.default.fileExists(atPath: directory)
                            ? git.optionalText(directory, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) : nil
                    }
                    guard let repository = repositories[directory] ?? nil else { continue }
                    snapshot["repository"] = repository
                    record[key] = snapshot
                    changed = true
                }
                guard changed, let updated = try? JSONSerialization.data(withJSONObject: record) else { continue }
                do { try updated.write(to: file, options: .atomic) }
                catch { AgentLog.error("checkpoint record kept as it was: \(file.lastPathComponent): \(error)") }
            }
        }
    }

    /// Only this session's own checkpoint refs are retired, after its bounded
    /// transcript has been persisted. In-flight baselines remain pinned.
    private func cleanupCheckpoints(_ saved: Saved) {
        let directory = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(saved.snapshot.session.description, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let turns = saved.snapshot.turns ?? []
        let retained = Set(turns.map(\.userItemID)).union(turns.compactMap { $0.checkpoint?.id })
        let finished = Set(turns.compactMap { $0.checkpoint?.id })
        let previous = retainedCheckpointIDs[saved.snapshot.session] ?? retained
        let retired = previous.subtracting(retained)
        retainedCheckpointIDs[saved.snapshot.session] = retained
        let store = checkpointStore
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            do {
                if name.hasPrefix("pending-") {
                    let id = String(name.dropFirst(8))
                    guard retired.contains(id) || finished.contains(id) else { continue }
                    let pending = try JSONDecoder().decode(AgentCheckpointPending.self, from: Data(contentsOf: file))
                    if !finished.contains(id) { try store.remove(pending.before) }
                } else {
                    guard retired.contains(name) else { continue }
                    let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
                    try store.remove(record.before)
                    try store.remove(record.after)
                }
                try FileManager.default.removeItem(at: file)
            } catch { AgentLog.error("agent checkpoint cleanup failed: \(error)") }
        }
    }

    /// Runs `body` on the writer unless the store has been released.
    private func write(_ body: @escaping () -> Void) {
        writer.async { [fence] in fence.write(body) }
    }

    /// `body`'s result, written on the writer, in order with every other change to the
    /// store's files, without holding the sessions queue. Refused once the store is released.
    private func written<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writer.async { [fence] in
                do {
                    var value: T?
                    guard try fence.write({ value = try body() }), let value else {
                        return continuation.resume(throwing: ServiceError(.badRequest, "The server is stopping"))
                    }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Writes `attachments` under `root` on the writer, queued now so they come before any
    /// clear or cleanup of the conversation's files asked for later; `nil` when there are none.
    private func stage(_ attachments: [AgentChatAttachment], root: URL) -> AgentStaging? {
        guard !attachments.isEmpty else { return nil }
        let staging = AgentStaging()
        writer.async { [fence] in
            do {
                var staged: [StagedAgentAttachment]?
                guard try fence.write({ staged = try AgentAttachments.stageRecorded(attachments, root: root) }), let staged else {
                    return staging.resolve(.failure(ServiceError(.badRequest, "The server is stopping")))
                }
                staging.resolve(.success(staged))
            } catch { staging.resolve(.failure(error)) }
        }
        return staging
    }

    private func persist(_ entry: Entry) {
        guard !entry.resetting, entries[entry.snapshot.session] === entry else { return }
        let retained = Set(entry.snapshot.items.lazy.filter { $0.kind == .user }.map(\.id))
        let saved = Saved(turnForkPoints: entry.turnForkPoints.filter { retained.contains($0.key) },
                          alwaysAllowedTools: entry.alwaysAllowedTools.isEmpty ? nil : entry.alwaysAllowedTools.sorted(),
                          snapshot: entry.snapshot, directory: entry.directory, hasSuccessfulTurn: entry.hasSuccessfulTurn,
                          forkSource: entry.forkSource, forkPoint: entry.forkPoint,
                          lastProviderMessage: entry.lastProviderMessage, archived: entry.archived ? true : nil)
        let file = root.appendingPathComponent(entry.snapshot.session.description + ".json")
        write {
            do {
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                self.cleanupCheckpoints(saved)
                self.cleanupOutputs(saved)
            } catch { AgentLog.error("agent checkpoint failed: \(error)") }
        }
    }
}

/// Files a message sends, written on the sessions' writer once it is admitted; its turn
/// awaits them without holding a thread.
final class AgentStaging: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[StagedAgentAttachment], Error>?
    private var waiting: [CheckedContinuation<[StagedAgentAttachment], Error>] = []

    func resolve(_ result: Result<[StagedAgentAttachment], Error>) {
        let waiting = lock.withLock { () -> [CheckedContinuation<[StagedAgentAttachment], Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            defer { self.waiting = [] }
            return self.waiting
        }
        for continuation in waiting { continuation.resume(with: result) }
    }

    func value() async throws -> [StagedAgentAttachment] {
        try await withCheckedThrowingContinuation { continuation in
            let settled = lock.withLock { () -> Result<[StagedAgentAttachment], Error>? in
                if let result { return result }
                waiting.append(continuation)
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }
}

/// A checkpoint's baseline, taken on its conversation's checkpoint queue. Work queued after
/// it there reads it at once; a turn waiting to start awaits it without holding a thread.
final class CheckpointBaseline: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var snapshot: AgentCheckpointStore.Snapshot?
    private var waiting: [CheckedContinuation<AgentCheckpointStore.Snapshot?, Never>] = []

    init() {}
    init(_ snapshot: AgentCheckpointStore.Snapshot) { settled = true; self.snapshot = snapshot }

    /// The baseline, or `nil` if it couldn't be taken or isn't yet.
    var taken: AgentCheckpointStore.Snapshot? { lock.withLock { snapshot } }

    func resolve(_ snapshot: AgentCheckpointStore.Snapshot?) {
        let waiters = lock.withLock { () -> [CheckedContinuation<AgentCheckpointStore.Snapshot?, Never>] in
            guard !settled else { return [] }
            settled = true
            self.snapshot = snapshot
            defer { waiting = [] }
            return waiting
        }
        for waiter in waiters { waiter.resume(returning: snapshot) }
    }

    func value() async -> AgentCheckpointStore.Snapshot? {
        await withCheckedContinuation { waiter in
            let ready = lock.withLock { () -> Bool in
                if settled { return true }
                waiting.append(waiter)
                return false
            }
            if ready { waiter.resume(returning: taken) }
        }
    }
}

/// A queued prompt's delivery was stopped before the agent received it.
struct AgentDeliveryNotStarted: LocalizedError {
    var errorDescription: String? { "Delivery was cancelled before it began." }
}

extension AgentSessions {
    private func mutateInbox(_ entry: Entry, _ change: (inout AgentPromptInbox) throws -> Void) throws {
        if let error = entry.inboxError { throw AgentRuntimeError("Queue storage is unavailable: " + error) }
        var next = entry.inbox
        try change(&next)
        entry.inbox = next
        entry.snapshot.queuedPrompts = next.visible
        entry.snapshot.queuePaused = next.paused
        touch(entry)
        persist(entry)
        let file = root.appendingPathComponent("inbox/" + entry.snapshot.session.description + ".json")
        let savedInbox = next
        write { [self] in
            do { try savedInbox.save(file) }
            catch {
                let message = "Queue could not be saved: " + error.localizedDescription
                queue.async { [self] in
                    entry.inboxError = message
                    entry.inbox.paused = true
                    entry.snapshot.queuePaused = true
                    entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
                    touch(entry)
                }
            }
        }
    }

    private func handleInbox(_ request: AgentChatRequest, entry: Entry) throws -> Bool {
        switch request {
        case .submit(_, let prompt):
            guard prompt.provider == entry.snapshot.provider || entry.snapshot.providerSession == nil else {
                throw AgentRuntimeError("An established conversation cannot switch providers.")
            }
            // A new message after a stop or failure is the user carrying on, so it
            // resumes the queue. Prompts that need review stay put, and a reconnect
            // resending a prompt already accepted changes nothing.
            try mutateInbox(entry) { inbox in
                let resent = inbox.records.contains { $0.id == prompt.id }
                try inbox.submit(prompt)
                guard !resent, inbox.paused else { return }
                inbox.paused = false
                // It answers what the user just saw, so it goes ahead of prompts held by the stop.
                if let first = inbox.records.firstIndex(where: { $0.display?.state == .queued }),
                   first < inbox.records.count - 1 {
                    inbox.records.insert(inbox.records.removeLast(), at: first)
                    for i in inbox.records.indices where inbox.records[i].display != nil { inbox.records[i].display?.revision += 1 }
                }
            }
            drainInbox(entry)
        case .editQueued(_, let id, let text, let revision, let settings):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                if let settings {
                    inbox.records[index].prompt?.model = settings.model
                    inbox.records[index].prompt?.effort = settings.effort
                    inbox.records[index].prompt?.planMode = settings.planMode
                }
                inbox.records[index].prompt?.text = text
                if let prompt = inbox.records[index].prompt { try prompt.validate() }
                inbox.records[index].display?.text = text
                inbox.records[index].display?.revision += 1
            }
        case .moveQueued(_, let id, let before, let revision):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                guard inbox.records[index].display?.state == .queued,
                      let target = inbox.records.firstIndex(where: { $0.id == before && $0.display?.state == .queued }), index != target else {
                    throw AgentRuntimeError("Only undelivered prompts can be reordered.")
                }
                let record = inbox.records.remove(at: index)
                inbox.records.insert(record, at: target > index ? target - 1 : target)
                for i in inbox.records.indices where inbox.records[i].display != nil { inbox.records[i].display?.revision += 1 }
            }
        case .removeQueued(_, let id, let revision):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                inbox.records[index].prompt = nil
                inbox.records[index].display = nil
            }
        case .resumeQueue:
            try mutateInbox(entry) { $0.paused = false }
            drainInbox(entry)
        case .deliverQueued(_, let id, let revision):
            let index = try entry.inbox.index(id, revision: revision)
            try deliverInbox(entry, index: index)
        default: return false
        }
        return true
    }

    private func drainInbox(_ entry: Entry) {
        // A failed turn pauses the queue, so only the user resuming it delivers after one.
        guard !stopping, entry.snapshot.status == .idle || entry.snapshot.status == .failed,
              !entry.submitting, entry.deliveryID == nil,
              entry.interrupting == nil, !entry.inbox.paused,
              let index = entry.inbox.records.firstIndex(where: { $0.display?.state == .queued }) else { return }
        do { try deliverInbox(entry, index: index) }
        catch {
            try? mutateInbox(entry) { $0.paused = true }
            entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Queue paused: " + error.localizedDescription))
            touch(entry)
        }
    }

    private func deliverInbox(_ entry: Entry, index: Int) throws {
        guard !entry.submitting, entry.deliveryID == nil, entry.interrupting == nil,
              entry.snapshot.status != .waiting, entry.snapshot.status != .closed,
              let prompt = entry.inbox.records[index].prompt else {
            throw AgentRuntimeError("Wait for the current interaction before delivering this prompt.")
        }
        if entry.snapshot.status == .working {
            guard prompt.model == entry.snapshot.model, prompt.effort == entry.snapshot.reasoningEffort,
                  prompt.provider == entry.snapshot.provider, prompt.planMode == (entry.snapshot.planMode == true) else {
                throw AgentRuntimeError("This prompt uses different model or plan settings. It must wait for the next turn.")
            }
        } else { entry.snapshot.planMode = prompt.planMode }
        try mutateInbox(entry) { inbox in
            inbox.records[index].display?.state = .delivering
            inbox.records[index].display?.error = nil
            inbox.records[index].display?.revision += 1
        }
        let attemptID = UUID().uuidString
        entry.deliveryID = attemptID
        entry.deliveryCancelled = false
        let id = entry.snapshot.session
        let delivered = Reply { [self] outcome in
            queue.async { [self] in
                entry.deliveryID = nil
                do {
                    try mutateInbox(entry) { inbox in
                        guard let index = inbox.records.firstIndex(where: { $0.id == prompt.id }) else { return }
                        switch outcome {
                        case .success(let snapshot) where snapshot.status != .failed && snapshot.status != .closed:
                            inbox.records[index].prompt = nil
                            inbox.records[index].display = nil
                        case .failure(let error) where error is AgentDeliveryNotStarted:
                            // The agent never saw it, so it waits in the held queue as it was.
                            inbox.paused = true
                            inbox.records[index].display?.state = .queued
                            inbox.records[index].display?.revision += 1
                        default:
                            inbox.paused = true
                            inbox.records[index].display?.state = .uncertain
                            inbox.records[index].display?.error = "Delivery did not finish cleanly. Review the conversation before sending again."
                            inbox.records[index].display?.revision += 1
                        }
                    }
                } catch { entry.inboxError = error.localizedDescription }
                drainInbox(entry)
            }
        }
        // The prompt is durably marked delivering before the provider sees it. Enqueued
        // now, the delivery starts ahead of the reply to the submit that queued it, so
        // that reply already shows the message in the conversation.
        writer.async { [self] in
            queue.async { [self] in
                do {
                    if let error = entry.inboxError { throw AgentRuntimeError(error) }
                    guard !stopping, entry.snapshot.status != .closed, entry.deliveryID == attemptID, !entry.deliveryCancelled else {
                        throw AgentDeliveryNotStarted()
                    }
                    try begin(.send(session: id, text: prompt.text, model: prompt.model, reasoningEffort: prompt.effort,
                                    provider: prompt.provider, attachments: prompt.attachments),
                              continuation: delivered, deliveryID: attemptID)
                } catch { delivered.resume(throwing: error) }
            }
        }
    }
}
