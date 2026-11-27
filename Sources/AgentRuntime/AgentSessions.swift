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
    /// Answers a request with one of the decisions its `AgentApprovalRequest` offered.
    func decide(request: String, decision: String, answers: [String: [String]]?) async throws
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
    /// Added to the provider's system prompt: where the agent runs.
    var instructions: String?
    /// The CLI, home folder, arguments and variables for the chosen provider.
    var provider: AgentProviderConfig?
}

extension AgentSessions {
    /// Whether two provider IDs name the same provider of `kind`; nil is its built-in one.
    static func sameProvider(_ a: String?, _ b: String?, kind: AgentChatProvider) -> Bool {
        (a ?? kind.rawValue) == (b ?? kind.rawValue)
    }

    /// Whether `prompt` runs on the conversation's current provider.
    static func keepsProvider(_ prompt: AgentPrompt, _ snapshot: AgentChatSnapshot) -> Bool {
        prompt.provider == snapshot.provider
            && (prompt.providerID == nil || sameProvider(prompt.providerID, snapshot.providerID, kind: snapshot.provider))
    }
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

    func decide(request: String, decision: String, answers: [String: [String]]?) async throws {
        throw AgentRuntimeError("This agent can't answer with the provider's own decisions.")
    }
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
        /// When the conversation was closed or archived; nil while it is open.
        var closedAt: Date?
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
        /// Reverts and rewinds admitted and not yet recorded: the conversation can't be cleared meanwhile.
        var reverts = 0
        /// Checkpoint captures queued or under way in this conversation's folder.
        var capturing = 0
        var stagingToolImages = false
        /// A turn's attachments by user item until they are written to disk, so previews
        /// of a message that was just sent never miss.
        var stagingAttachments: [String: [AgentChatAttachment]] = [:]
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
        /// The provider changed after the conversation began, and the new one hasn't named
        /// its conversation yet: each message carries the transcript, as `AgentHandoff` writes it.
        var handoffFrom: String?
        /// Each agent's own steps, by the tool call that started it, while its provider process
        /// runs; saved under `children/` and read from there once it stops.
        var subagentSteps: [String: AgentChildTranscript] = [:]
        /// Agents whose steps changed since they were last saved, and whether a save is due.
        var unsavedChildren: Set<String> = []
        var childSaveScheduled = false
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
        /// The runtime stopped during a turn that carries on when it starts again; see
        /// `AgentRestartResume`.
        var resumeAfterRestart = false

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

    struct Saved: Codable {
        var turnForkPoints: [String: ForkPoint]?
        var alwaysAllowedTools: [String]?
        var snapshot: AgentChatSnapshot
        var directory: String
        var hasSuccessfulTurn: Bool?
        var forkSource: String?
        var forkPoint: String?
        var lastProviderMessage: String?
        /// Absent from records saved before providers could take over a conversation.
        var handoffFrom: String?
        var archived: Bool?
        /// When it was closed; absent from records saved before close times were kept.
        var closedAt: Date?
        /// Absent from records saved before interrupted turns carried on after a restart.
        var resumeAfterRestart: Bool?
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
    /// Writes records and removes files, in the order asked. Internal so tests can hold it.
    let writer: DispatchQueue
    /// Closed once the store is released to its next owner: nothing is written after.
    private let fence = AgentStoreFence()
    /// Line indexes of the archives of dropped items, so paging back stays cheap at any length.
    private let earlierArchive = AgentEarlierArchive()
    /// Takes and removes checkpoints.
    private let checkpointStore: AgentCheckpointStore
    /// Checkpoints being taken and reverts being applied. Each changes refs, files and
    /// records the store's next owner must find whole, so shutdown waits for them.
    private let storeWork = DispatchGroup()
    /// How long shutdown waits for them; `nil`, the default, waits until they end, which
    /// Git's own time limits bound. With a limit, the store stays held until they end.
    var checkpointDrain: TimeInterval?
    private var retainedCheckpointIDs: [SessionId: Set<String>] = [:] // writer queue only
    /// Restores being applied, each holding back work that may change its files. Confined to `queue`.
    private var restoring: [UUID: AgentRestoreReservation] = [:]
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
    /// The provider settings a conversation of a kind runs with, given the ID it chose.
    var providers: @Sendable (String?, AgentChatProvider) -> AgentProviderConfig = { _, kind in .builtIn(kind) }
    var stageToolImages: @Sendable ([AgentChatAttachment], URL) throws -> Void = { images, directory in
        let staged = try AgentAttachments.stageToolImages(images, root: directory)
        try AgentAttachments.record(staged, root: directory)
    }
    private var entries: [SessionId: Entry] = [:]
    /// How long closed conversations are kept; the host chooses.
    let retention: AgentConversationRetention
    /// The clock retention and scheduled retries read; tests advance it.
    let now: @Sendable () -> Date
    /// Stores beside the conversation record that delete their part when a conversation is
    /// permanently deleted; see `AgentDeletionCleanup`.
    private let deletionCleanups: [AgentDeletionCleanup]
    /// Told, on the callbacks queue, once a conversation and everything kept only for it are gone.
    var conversationDeleted: @Sendable (SessionId) -> Void = { _ in }
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
         retention: AgentConversationRetention = .keepClosed,
         now: @escaping @Sendable () -> Date = { Date() },
         deletionCleanups: [AgentDeletionCleanup] = [],
         writer: DispatchQueue = DispatchQueue(label: "tab.agents.persistence", qos: .utility),
         checkpoints: AgentCheckpointStore = AgentCheckpointStore(),
         factory: @escaping Factory = { provider, directory, resume, callback -> any AgentSessionRuntime in
             provider.spec.wire == .acp
                 ? AcpAgentRuntime(provider: provider, directory: directory, resumeSession: resume, onEvent: callback)
                 : AgentRuntime(provider: provider, directory: directory, resumeSession: resume, onEvent: callback)
         }) throws {
        self.root = root
        self.writer = writer
        self.checkpointStore = checkpoints
        self.factory = factory
        self.projectDirectory = projectDirectory
        self.submissionTimeout = submissionTimeout
        self.interruptTimeout = interruptTimeout
        self.changed = changed
        self.retention = retention
        self.now = now
        self.deletionCleanups = deletionCleanups
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        callbacks.setSpecific(key: Self.callbackKey, value: ObjectIdentifier(self))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Listed before anything is queued, so a store that can't be read leaves no work
        // running after this fails.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        resumeRemovals()
        let now = now()
        for file in files where file.pathExtension == "json" {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= AgentLimits.maxFrame else {
                    continue
                }
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == saved.snapshot.session.description else {
                    continue
                }
                // A record from before close times were kept takes its last change as its close
                // time, which the earlier implicit rule measured; it is saved below.
                let closedAt = saved.snapshot.status != .closed ? nil
                    : saved.closedAt ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                // The host's retention deletes a conversation closed long enough, with everything kept only for it.
                if let closedAt, let expiry = retention.expiry(closedAt: closedAt), now > expiry {
                    writer.async { self.removeConversation(saved, file: file) }
                    continue
                }
                let entry = Entry(saved.snapshot, directory: saved.directory)
                entry.closedAt = closedAt
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
                entry.handoffFrom = saved.handoffFrom
                entry.turnForkPoints = saved.turnForkPoints ?? [:]
                entry.alwaysAllowedTools = Set(saved.alwaysAllowedTools ?? [])
                entry.resumeAfterRestart = saved.resumeAfterRestart == true && !entry.archived
                    && entry.snapshot.status == .failed
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
                    // The previous runtime ended without stopping the turn, as when the app crashed.
                    entry.resumeAfterRestart = !entry.archived
                        && AgentRestartResume.resumes(entry.snapshot, handoff: entry.handoffFrom != nil)
                    interrupted(entry, message: entry.resumeAfterRestart ? AgentRestartResume.stoppedNotice
                        : AgentRestartResume.interruptedNotice)
                } else {
                    updateTurn(entry, status: entry.snapshot.status)
                }
                entries[entry.snapshot.session] = entry
                recordItemRevisions(entry)
                persist(entry)
                armRetries(entry)
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

    /// Carries on turns the previous runtime stopping cut short. The runtime calls it once it
    /// has set up how providers launch, as a resume starts a provider.
    func resumeWorkEndedByRestart() {
        queue.async { [self] in
            for entry in entries.values where entry.resumeAfterRestart { resumeAfterRestart(entry) }
        }
    }

    /// Relaunches `entry`'s provider on its conversation and asks it to continue the turn the
    /// runtime stopping cut short. Call on `queue`.
    private func resumeAfterRestart(_ entry: Entry) {
        entry.resumeAfterRestart = false
        guard !stopping, entry.snapshot.status == .failed else { persist(entry); return }
        let snapshot = entry.snapshot
        do {
            try begin(.send(session: snapshot.session, text: AgentRestartResume.prompt, model: snapshot.model,
                            reasoningEffort: snapshot.reasoningEffort, provider: snapshot.provider,
                            attachments: nil, providerID: snapshot.providerID),
                      continuation: Reply { _ in }, restartResume: true)
        } catch {
            entry.snapshot.items.append(AgentChatItem(kind: .notice, text:
                "The agent couldn't continue after the restart: \(error.localizedDescription) Send a message to resume."))
            touch(entry)
            persist(entry)
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
        if case .retryTurn(let session, let turn) = request { return try await retryRateLimitedTurn(session: session, turn: turn) }
        let submissionContext: (SessionId, SessionId?)? = queue.sync {
            let id: SessionId
            switch request {
            case .submit(let session, _), .send(let session, _, _, _, _, _, _): id = session
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
        case .send(let id, let value, _, _, let selected, let files, _): session = id; text = value; provider = selected; attachments = files ?? []
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
        case .send(let session, let text, let model, let effort, let provider, _, let providerID):
            return .send(session: session, text: text, model: model, reasoningEffort: effort, provider: provider, attachments: files,
                         providerID: providerID)
        default: return request
        }
    }

    func attachment(_ request: AgentAttachmentRequest) async throws -> AgentAttachmentReply {
        try request.validate()
        let (descriptor, inMemory) = queue.sync { () -> (AgentChatAttachmentDescriptor?, AgentChatAttachment?) in
            let entry = entries[request.session]
            if let staging = entry?.stagingAttachments[request.item]?.first(where: { $0.id == request.attachment }) {
                return (nil, staging)
            }
            let sent = entry?.snapshot.items.first { $0.id == request.item }?.attachments?.first { $0.id == request.attachment }
            // A queued prompt's attachments are still held whole in its inbox record.
            let held = sent == nil ? entry?.inbox.records.first { $0.id == request.item && $0.display != nil }?
                .prompt?.attachments.first { $0.id == request.attachment } : nil
            return (sent, held)
        }
        if let inMemory { return AgentAttachmentReply(attachment: inMemory) }
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
            return .subagentSteps(try await childSteps(session: session, toolUseID: toolUseID, before: nil))
        case .subagentStepsPage(let session, let toolUseID, let before, let limit):
            return .subagentSteps(try await childSteps(session: session, toolUseID: toolUseID, before: before, limit: limit))
        case .revert(let session, let checkpoint, let paths, let force):
            return .revert(try await revert(session: session, checkpoint: checkpoint, paths: paths, force: force))
        case .rewind(let session, let at, let archive, let revision, let restoreFiles, let force):
            return .rewound(try await rewind(session: session, at: at, archive: archive, revision: revision,
                                             restoreFiles: restoreFiles, force: force))
        case .retryCheckpoint(let session, let turn):
            return .snapshot(try await retryCheckpoint(session: session, turn: turn))
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
    /// Admitted only while no other conversation works in the same physical folder and no
    /// other restore changes it; see `admitRestore`.
    private func revert(session: SessionId, checkpoint: String, paths: [String]?, force: Bool) async throws -> AgentRevertReply {
        let file = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
            .appendingPathComponent(checkpoint + ".json")
        let store = checkpointStore
        let (scope, folders) = try await restoreSurroundings(session)
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
                    try checkProvidersStopped(in: scope)
                    let token = try admitRestore(entry, folders: folders, holdsOwner: false)
                    entry.reverts += 1
                    storeWork.enter()
                    revertAdmitted?()
                    let captures = restoring[token]?.captures ?? []
                    // Applied and recorded on Dispatch, so shutdown, which may block every
                    // Swift task worker, never waits on one.
                    entry.checkpoints.async { [self] in
                        defer { storeWork.leave() }
                        // Captures other conversations had under way here finish first.
                        for other in captures { other.sync {} }
                        let result = Result { () throws -> AgentRevertReply in
                            let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
                            return try AgentRestoreWork.revert(record, paths: paths, force: force, store: store)
                        }
                        queue.sync {
                            entry.reverts -= 1
                            // Released once recorded, so work it held back comes after its notice.
                            defer { finishRestore(token) }
                            guard entries[session] === entry, entry.snapshot.status != .closed else { return }
                            let notice: String
                            switch result {
                            case .success(let reply) where !reply.reverted.isEmpty:
                                let count = reply.reverted.count
                                notice = "Reverted \(count == 1 ? "1 file" : "\(count) files") to before a turn."
                            case .failure(let failure as AgentRestoreFailure) where !failure.changed.isEmpty:
                                notice = "A revert stopped part way. " + (failure.errorDescription ?? "")
                            default: return
                            }
                            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: notice), entry: entry))
                            touch(entry)
                            persist(entry)
                        }
                        continuation.resume(with: result)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Reserves `entry`'s folder for a restore, or says why it can't be: another restore
    /// changes files in the same physical folder, one inside it or one around it, however its
    /// path is spelled, or another conversation works there. While reserved, those
    /// conversations start no turn and deliver nothing from their queues, and the restore
    /// applies after the captures they have under way. `entry`'s own work is the caller's to check. Call on `queue`; the caller calls
    /// `finishRestore` on `queue` once the restore is applied and recorded.
    private func admitRestore(_ entry: Entry, folders: [String: AgentRestoreFolder], holdsOwner: Bool) throws -> UUID {
        let session = entry.snapshot.session
        guard let mine = folders[entry.directory] else {
            throw AgentRuntimeError("This conversation's folder changed while the revert was being prepared. Try again.")
        }
        if restoring.values.contains(where: { $0.owner == session || $0.competes(with: mine.folder) || $0.holds(session, directory: entry.directory) }) {
            throw AgentRuntimeError("Another revert is being applied in this folder. Try again when it finishes.")
        }
        let reservation = AgentRestoreReservation(owner: session, folder: mine, held: [], holdsOwner: holdsOwner)
        var held: Set<SessionId> = []
        var captures: [DispatchQueue] = []
        for other in entries.values where other !== entry {
            let overlaps = folders[other.directory].map { $0.folder.overlaps(mine.folder) }
                ?? reservation.holds(other.snapshot.session, directory: other.directory)
            guard overlaps else { continue }
            if other.snapshot.status == .closed, other.runtime == nil, !other.submitting, other.capturing == 0 { continue }
            if let reason = AgentRestoreWork.blocker(submitting: other.submitting, delivering: other.deliveryID != nil,
                    status: other.snapshot.status, runningAgents: other.snapshot.subagents?.contains(where: { $0.status == .running }) == true) {
                throw AgentRuntimeError(reason)
            }
            held.insert(other.snapshot.session)
            if other.capturing > 0 { captures.append(other.checkpoints) }
        }
        let token = UUID()
        var admitted = AgentRestoreReservation(owner: session, folder: mine, held: held, holdsOwner: holdsOwner)
        admitted.captures = captures
        restoring[token] = admitted
        return token
    }

    /// Releases a restore's reservation and lets the work it held back go on. Call on `queue`.
    private func finishRestore(_ token: UUID) {
        guard let reservation = restoring.removeValue(forKey: token) else { return }
        for other in entries.values where other.snapshot.session == reservation.owner
            || reservation.holds(other.snapshot.session, directory: other.directory) {
            drainInbox(other)
        }
    }

    /// Whether a restore holds back work that may change `entry`'s files. Call on `queue`.
    private func restoreHolds(_ entry: Entry) -> Bool {
        restoring.values.contains { $0.holds(entry.snapshot.session, directory: entry.directory) }
    }

    /// What a restore in `session`'s folder must look at, read off the sessions queue as either
    /// may be on a slow volume: where each provider that may still run works now, and every
    /// conversation's folder.
    private func restoreSurroundings(_ session: SessionId) async throws -> (AgentRevertScope?, [String: AgentRestoreFolder]) {
        let (directory, runtimes, directories) = queue.sync {
            (entries[session]?.directory, entries.values.compactMap(\.runtime), Set(entries.values.map(\.directory)))
        }
        let candidates = (runtimes + retiring.withLock { Array($0.values) }).flatMap { $0.providerProcesses() } + otherProviderProcesses()
        return try await runBlocking { () -> (AgentRevertScope?, [String: AgentRestoreFolder]) in
            (directory.map { AgentRevertScope(directory: $0, candidates: candidates) }, AgentRestoreFolder.read(directories))
        }
    }

    /// Refuses a restore while a provider stopping in the same folder, or in one inside or
    /// around it, whichever conversation's, may still change its files. Call on `queue`.
    private func checkProvidersStopped(in scope: AgentRevertScope?) throws {
        guard let scope else { return }
        let stopping = retiring.withLock { $0.values.contains { $0.mayRun(in: scope) } }
            || entries.values.contains { $0.runtime?.isStopping(in: scope) == true }
            || otherProvidersMayRun(scope)
        guard !stopping else { throw AgentRuntimeError("The agent is still stopping. Try again shortly.") }
    }

    /// Edit from Here; see `AgentConversationRequest.rewind`. Files are restored first, under a
    /// reservation like a revert's and after the conversation's checkpoints; only once that
    /// succeeds is the conversation archived whole and rewound, so a refusal or failure leaves
    /// the transcript, provider context and files as they were, or says exactly which files changed.
    private func rewind(session: SessionId, at: String, archive id: SessionId, revision: UInt64,
                        restoreFiles: Bool, force: Bool) async throws -> AgentRewindReply {
        let (scope, folders) = restoreFiles ? try await restoreSurroundings(session) : (nil, [:])
        let directory = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
        let store = checkpointStore
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                    let affected = try rewindTurns(entry, at: at, archive: id, revision: revision)
                    if restoreFiles, let missing = affected.first(where: { $0.checkpoint == nil }) {
                        let number = (entry.snapshot.turns?.firstIndex(of: missing) ?? 0) + 1
                        throw AgentRuntimeError("Turn \(number) has no recorded file changes, so files can't be restored. Rewind and keep the files instead.")
                    }
                    let token: UUID
                    if restoreFiles {
                        try checkProvidersStopped(in: scope)
                        token = try admitRestore(entry, folders: folders, holdsOwner: true)
                    } else {
                        token = UUID()
                        restoring[token] = AgentRestoreReservation(owner: session, folder: nil, held: [], holdsOwner: true)
                    }
                    entry.reverts += 1
                    storeWork.enter()
                    let checkpoints = restoreFiles ? affected.compactMap { $0.checkpoint?.id } : []
                    let captures = restoring[token]?.captures ?? []
                    let reply = RewindReply { result in
                        continuation.resume(with: result.map { AgentRewindReply(snapshot: $0.snapshot, files: $0.files) })
                    }
                    // After checkpoints being taken; a turn can't start meanwhile, as the reservation holds it.
                    entry.checkpoints.async { [self] in
                        defer { storeWork.leave() }
                        for other in captures { other.sync {} }
                        let files = Result { () throws -> AgentRevertReply in
                            let records = try checkpoints.map {
                                try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: directory.appendingPathComponent($0 + ".json")))
                            }
                            return try AgentRestoreWork.rewind(records, force: force, store: store)
                        }
                        // The commit is queued on the writer before this leaves the store's work,
                        // so shutdown waits for it.
                        queue.sync { settleRewind(entry, at: at, archive: id, revision: revision, token: token, files: files, reply: reply) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Where a rewind goes once its files are restored or it found conflicts. Call on `queue`.
    private func settleRewind(_ entry: Entry, at: String, archive id: SessionId, revision: UInt64, token: UUID,
                              files: Result<AgentRevertReply, Error>, reply: RewindReply) {
        let release = { [self] in
            entry.reverts -= 1
            finishRestore(token)
        }
        let restored: AgentRevertReply
        switch files {
        case .failure(let error):
            release()
            if let failure = error as? AgentRestoreFailure, !failure.changed.isEmpty, entries[entry.snapshot.session] === entry {
                entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice,
                    text: "Editing from here stopped part way. " + (failure.errorDescription ?? "")), entry: entry))
                touch(entry)
                persist(entry)
            }
            return reply.resume(throwing: error)
        case .success(let value): restored = value
        }
        guard restored.conflicts.isEmpty else {
            release()
            return reply.resume(returning: (nil, restored))
        }
        do {
            _ = try rewindTurns(entry, at: at, archive: id, revision: revision, restoring: true)
        } catch {
            release()
            guard restored.reverted.isEmpty else {
                return reply.resume(throwing: AgentRuntimeError("Restored \(restored.reverted.joined(separator: ", ")), but the conversation changed meanwhile, so it wasn't rewound: \(error.localizedDescription)"))
            }
            return reply.resume(throwing: error)
        }
        commitRewind(entry, at: at, archive: id, token: token, restored: restored, reply: reply)
    }

    /// Answers a rewind: the rewound conversation and the files put back, or why not.
    private struct RewindReply: Sendable {
        let complete: @Sendable (Result<(snapshot: AgentChatSnapshot?, files: AgentRevertReply), Error>) -> Void
        init(_ complete: @escaping @Sendable (Result<(snapshot: AgentChatSnapshot?, files: AgentRevertReply), Error>) -> Void) {
            self.complete = complete
        }
        func resume(returning value: (AgentChatSnapshot?, AgentRevertReply)) { complete(.success(value)) }
        func resume(throwing error: Error) { complete(.failure(error)) }
    }

    /// The turns rewinding `entry` to before its user message `at` removes, oldest first, or
    /// why it can't be rewound there now. With `restoring`, its own restore is under way.
    private func rewindTurns(_ entry: Entry, at: String, archive id: SessionId, revision: UInt64,
                             restoring: Bool = false) throws -> [AgentChatTurn] {
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        guard !entry.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
        guard entry.snapshot.status != .closed, !entry.archived else { throw ServiceError(.badRequest, "This conversation is closed or archived.") }
        guard entry.snapshot.revision == revision, entries[id] == nil else {
            throw AgentRuntimeError("The conversation changed. Review it before editing from here.")
        }
        guard entry.snapshot.provider == .claude else {
            throw ServiceError(.badRequest, "\(entry.snapshot.provider.name) can't continue from an earlier message. Use Edit as New Prompt or start a new conversation.")
        }
        guard entry.snapshot.items.contains(where: { $0.id == at && $0.kind == .user && !$0.isProviderTurn }),
              let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == at }),
              entry.snapshot.turns?[index].rewindable == true else {
            throw ServiceError(.badRequest, "This conversation can't be rewound to that message.")
        }
        guard !entry.submitting, entry.deliveryID == nil,
              entry.snapshot.status == .idle || entry.snapshot.status == .failed,
              entry.inbox.visible.isEmpty,
              entry.snapshot.subagents?.contains(where: { $0.status == .running }) != true else {
            throw AgentRuntimeError("Stop active work and remove queued prompts before editing from here. Your conversation is kept.")
        }
        guard !importing.contains(entry.snapshot.session) else {
            throw AgentRuntimeError("A past conversation is being continued here. Try again shortly.")
        }
        guard restoring || (entry.reverts == 0 && !restoreHolds(entry)) else {
            throw AgentRuntimeError("Files are being restored for this conversation. Try again when it finishes.")
        }
        guard restoring || entry.capturing == 0 else {
            throw AgentRuntimeError("The last turn's changes are still being recorded. Try again shortly.")
        }
        return Array(entry.snapshot.turns?[index...] ?? [])
    }

    /// Archives `entry` whole as `id`, as a clear does, and leaves it holding only what came
    /// before its message `at`, its provider continuing from the message before it. The
    /// archive owns the removed turns' checkpoints; the conversation keeps the rest. Call on `queue`.
    private func commitRewind(_ entry: Entry, at: String, archive id: SessionId, token: UUID,
                              restored: AgentRevertReply, reply: RewindReply) {
        let session = entry.snapshot.session
        guard let cut = entry.snapshot.items.firstIndex(where: { $0.id == at }),
              let turnIndex = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == at }) else {
            entry.reverts -= 1
            finishRestore(token)
            return reply.resume(throwing: ServiceError(.badRequest, "This conversation can't be rewound to that message."))
        }
        let turns = entry.snapshot.turns ?? []
        let removed = Set(turns[turnIndex...].map(\.userItemID))
        let first = !entry.snapshot.items[..<cut].contains { $0.kind == .user && !$0.isProviderTurn }
        let point = first ? nil : entry.turnForkPoints[at]
        var archived = entry.snapshot
        archived.session = id; archived.status = .closed; archived.resetID = nil
        // The conversation keeps its earlier turns' checkpoints, so the archive doesn't show them.
        archived.turns = turns.map { turn in
            guard !removed.contains(turn.userItemID) else { return turn }
            var kept = turn
            kept.checkpoint = nil; kept.checkpointStatus = nil
            return kept
        }
        let saved = Saved(turnForkPoints: entry.turnForkPoints, snapshot: archived, directory: entry.directory,
            hasSuccessfulTurn: entry.hasSuccessfulTurn, forkSource: entry.forkSource, forkPoint: entry.forkPoint,
            lastProviderMessage: entry.lastProviderMessage, archived: true)
        var fresh = entry.snapshot
        fresh.items = Array(entry.snapshot.items[..<cut])
        fresh.turns = Array(turns[..<turnIndex])
        fresh.revision = archived.revision + 1
        fresh.status = .idle
        fresh.resetID = id
        fresh.providerSession = point?.session
        fresh.contextUsage = nil
        fresh.activity = nil
        fresh.subagents = nil
        let kept = Set(fresh.items.lazy.filter { $0.kind == .user }.map(\.id))
        let forkPoints = entry.turnForkPoints.filter { kept.contains($0.key) }
        let count = restored.reverted.count
        fresh.items.append(AgentChatItem(kind: .notice, text: count == 0
            ? "Rewound to before a message. The full conversation is kept in history."
            : "Rewound to before a message and restored \(count == 1 ? "1 file" : "\(count) files"). The full conversation is kept in history."))
        let replacement = Saved(turnForkPoints: forkPoints, alwaysAllowedTools: entry.alwaysAllowedTools.isEmpty ? nil : entry.alwaysAllowedTools.sorted(),
            snapshot: fresh, directory: entry.directory, hasSuccessfulTurn: !first,
            forkSource: point?.session, forkPoint: point?.message, lastProviderMessage: point?.message)
        let oldEarlier = earlierFile(session: session)
        let newEarlier = root.appendingPathComponent("earlier", isDirectory: true)
            .appendingPathComponent(session.description + "-" + id.description + ".jsonl")
        entry.resetting = true
        retireRuntime(entry)
        let next = fresh, previous = archived
        writer.async { [self] in
            do {
                // Copied before committing: a failed archive leaves the original readable.
                for folder in ["attachments", "outputs"] {
                    try Self.copyAnew(root.appendingPathComponent(folder + "/" + session.description),
                                      to: root.appendingPathComponent(folder + "/" + id.description))
                }
                let checkpoints = root.appendingPathComponent("checkpoints/" + session.description)
                let archivedCheckpoints = root.appendingPathComponent("checkpoints/" + id.description)
                var moved: [URL] = []
                for file in (try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)) ?? []
                    where file.pathExtension == "json" && removed.contains(Self.checkpointID(file.deletingPathExtension().lastPathComponent)) {
                    try FileManager.default.createDirectory(at: archivedCheckpoints, withIntermediateDirectories: true)
                    try Self.copyAnew(file, to: archivedCheckpoints.appendingPathComponent(file.lastPathComponent))
                    moved.append(file)
                }
                try Self.copyAnew(oldEarlier, to: root.appendingPathComponent("earlier/" + id.description + ".jsonl"))
                if oldEarlier != newEarlier { try Self.copyAnew(oldEarlier, to: newEarlier) }
                try JSONEncoder().encode(saved).write(to: root.appendingPathComponent(id.description + ".json"), options: .atomic)
                try JSONEncoder().encode(replacement).write(to: root.appendingPathComponent(session.description + ".json"), options: .atomic)
                retainedCheckpointIDs[id] = removed
                retainedCheckpointIDs[session] = (retainedCheckpointIDs[session] ?? []).subtracting(removed)
                // The archive now owns the removed turns' records and Git refs; a restart before
                // this finds them as the archive's, as after a clear.
                for original in moved + (oldEarlier == newEarlier ? [] : [oldEarlier]) where FileManager.default.fileExists(atPath: original.path) {
                    do { try FileManager.default.removeItem(at: original) }
                    catch { AgentLog.error("rewound conversation files could not be retired: \(error)") }
                }
                queue.async { [self] in
                    let replacementEntry = Entry(next, directory: entry.directory)
                    replacementEntry.inbox = entry.inbox
                    replacementEntry.hasSuccessfulTurn = !first
                    replacementEntry.turnForkPoints = forkPoints
                    replacementEntry.alwaysAllowedTools = entry.alwaysAllowedTools
                    replacementEntry.forkSource = point?.session
                    replacementEntry.forkPoint = point?.message
                    replacementEntry.lastProviderMessage = point?.message
                    let archiveEntry = Entry(previous, directory: entry.directory)
                    archiveEntry.archived = true
                    archiveEntry.turnForkPoints = entry.turnForkPoints
                    archiveEntry.forkSource = entry.forkSource; archiveEntry.forkPoint = entry.forkPoint
                    archiveEntry.lastProviderMessage = entry.lastProviderMessage
                    entries[id] = archiveEntry
                    entries[session] = replacementEntry
                    entry.reverts -= 1
                    recordItemRevisions(replacementEntry)
                    finishRestore(token)
                    notifyChanged(session, next.revision)
                    notifyActivity(next, entry.directory)
                    reply.resume(returning: (next, restored))
                }
            } catch {
                queue.async { [self] in
                    entry.resetting = false
                    entry.reverts -= 1
                    finishRestore(token)
                    let files = restored.reverted.isEmpty ? "" : " Restored files stay restored: " + restored.reverted.joined(separator: ", ") + "."
                    reply.resume(throwing: AgentRuntimeError("The conversation couldn't be rewound: " + error.localizedDescription + files))
                }
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
                var content = try store.diff(from: record.before, to: record.after, path: path, context: request.context ?? 3)
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
                totalFiles: record.files.count, nextOffset: end < record.files.count ? end : nil, path: request.path, diff: diff,
                context: request.path == nil ? nil : request.context ?? 3)
            try reply.validate()
            return reply
        }
    }

    /// `restartResume` carries on a turn the runtime stopping cut short; see `AgentRestartResume`.
    private func begin(_ request: AgentChatRequest,
                       continuation: Reply, deliveryID: String? = nil, restartResume: Bool = false) throws {
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
        case .clear(let session, _, _), .read(let session), .send(let session, _, _, _, _, _, _), .approve(let session, _, _, _, _),
             .interrupt(let session), .close(let session), .setAccess(let session, _), .setPlan(let session, _): id = session
        case .submit(let session, _), .editQueued(let session, _, _, _, _), .removeQueued(let session, _, _),
             .deliverQueued(let session, _, _), .moveQueued(let session, _, _, _), .resumeQueue(let session), .answer(let session, _, _, _),
             .decide(let session, _, _, _), .retryTurn(let session, _), .scheduleRetry(let session, _, _),
             .updateQueued(let session, _, _, _): id = session
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
        if case .scheduleRetry(_, let turn, let enabled) = request {
            try scheduleRetry(entry, turn: turn, enabled: enabled)
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .retryTurn = request { throw ServiceError(.badRequest, "Unexpected retry") }
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
        case .send(_, let text, _, _, let provider, let attachments, _): submitted = (text, provider ?? entry.snapshot.provider, attachments?.isEmpty == false)
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
        var turnAttachmentFiles: (attachments: [AgentChatAttachment], staging: AgentStaging?, item: String)?
        var handoff: AgentHandoff?
        if case .send(_, let text, let model, let effort, let requestedProvider, let attachments, let requestedProviderID) = request {
            guard entry.deliveryID == nil || entry.deliveryID == deliveryID else {
                throw ServiceError(.badRequest, "A queued prompt is being delivered.")
            }
            // A restore in this folder holds the message back: it would change files the restore puts back.
            if restoreHolds(entry) {
                if deliveryID != nil { throw AgentDeliveryNotStarted() }
                throw AgentRuntimeError(AgentRestoreWork.holdMessage)
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            if !entry.submitting, entry.snapshot.status == .working, let runtime = entry.runtime {
                guard requestedProvider == nil || requestedProvider == entry.snapshot.provider,
                      requestedProviderID == nil || Self.sameProvider(requestedProviderID, entry.snapshot.providerID, kind: entry.snapshot.provider),
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
            // A prompt without a provider ID keeps the conversation's provider of its kind.
            let providerID = requestedProviderID ?? (provider == entry.snapshot.provider ? entry.snapshot.providerID : nil)
            let switching = provider != entry.snapshot.provider
                || !Self.sameProvider(providerID, entry.snapshot.providerID, kind: provider)
            // Another provider takes over an established conversation from its transcript.
            let handingOff = switching && (entry.snapshot.providerSession != nil || entry.hasSuccessfulTurn
                || entry.forkSource != nil || entry.handoffFrom != nil)
            if switching {
                guard entry.snapshot.status == .idle || entry.snapshot.status == .failed else {
                    throw ServiceError(.badRequest, "Provider changes apply after the current response.")
                }
            }
            if let effort, !effort.isAccepted(provider: provider, model: model) {
                throw ServiceError(.badRequest, "\(provider.name) does not support \(effort.title) reasoning for this model")
            }
            let config = providers(providerID, provider)
            if !config.enabled, entry.snapshot.providerSession == nil || switching {
                throw ServiceError(.badRequest, "\(config.title) is disabled. Enable it or choose another provider.")
            }
            let restart = switching
                || (provider == .claude && (model != entry.snapshot.model || effort != entry.snapshot.reasoningEffort))
            if restart, !switching {
                guard !entry.hasSuccessfulTurn || entry.snapshot.providerSession != nil else {
                    throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
                }
            }
            if entry.runtime == nil, entry.hasSuccessfulTurn, entry.snapshot.providerSession == nil,
               !handingOff, entry.handoffFrom == nil {
                throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
            }
            let userID = deliveryID ?? UUID().uuidString
            let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
                .appendingPathComponent(userID, isDirectory: true)
            do {
                try AgentAttachments.validateForStaging(attachments ?? [])
                turnAttachmentFiles = (attachments ?? [], stage(attachments ?? [], root: attachmentRoot), userID)
            } catch {
                throw ServiceError(.badRequest, error.localizedDescription)
            }
            if restart, entry.runtime != nil {
                retireRuntime(entry, reason: switching ? "the provider changed"
                    : "the model or reasoning effort changed, which restarts Claude")
            }
            if switching || model != entry.snapshot.model {
                entry.snapshot.contextUsage = nil
                entry.snapshot.resolvedModel = nil
            }
            if handingOff {
                // Neither the old provider's conversation nor its fork points can carry on
                // under the new one, so earlier turns no longer rewind.
                entry.handoffFrom = entry.handoffFrom ?? providers(entry.snapshot.providerID, entry.snapshot.provider).title
                entry.snapshot.providerSession = nil
                entry.forkSource = nil
                entry.forkPoint = nil
                entry.lastProviderMessage = nil
                entry.turnForkPoints.removeAll()
                for index in (entry.snapshot.turns ?? []).indices { entry.snapshot.turns?[index].rewindable = false }
                entry.snapshot.items.append(AgentChatItem(kind: .notice, text:
                    "Switched to \(config.title). It reads the conversation so far with your next message."))
            }
            if let previous = entry.handoffFrom {
                handoff = AgentHandoff(previousProvider: previous, items: entry.snapshot.items,
                                       earlierFile: earlierFile(session: id))
            }
            entry.snapshot.provider = provider
            // Kept as named: without an ID the conversation runs the first configured provider
            // of its kind, which need not be the built-in one asked for.
            entry.snapshot.providerID = providerID
            entry.resumeAfterRestart = false
            let user = AgentChatItem(id: userID, kind: .user, text: restartResume ? AgentRestartResume.note : text,
                                     attachments: attachments?.map(\.descriptor),
                                     workContext: restartResume ? .init(itemType: AgentChatItem.restartResumeType) : nil)
            let firstMessage = !entry.snapshot.items.contains { $0.kind == .user && !$0.isProviderTurn }
            entry.snapshot.items.append(observedItem(user, entry: entry))
            if let session = entry.snapshot.providerSession, let message = entry.lastProviderMessage {
                entry.turnForkPoints[user.id] = ForkPoint(session: session, message: message)
            }
            // A turn begun since makes an earlier failed recording's result include its work.
            for index in (entry.snapshot.turns ?? []).indices where entry.snapshot.turns?[index].checkpointStatus?.retryable == true {
                entry.snapshot.turns?[index].checkpointStatus?.retryable = false
            }
            var turn = AgentChatTurn(userItemID: user.id, startedAt: Date())
            if capturesCheckpoints { turn.checkpointStatus = AgentChatTurn.checkpointCapturing }
            // Claude resumes at the message before this one, or starts afresh before the first.
            turn.rewindable = provider == .claude && (firstMessage || entry.turnForkPoints[user.id] != nil)
            entry.snapshot.turns = (entry.snapshot.turns ?? []) + [turn]
            let captureDirectory = entry.directory
            let pendingDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
            entry.baseline = nil
            if capturesCheckpoints {
                let baseline = CheckpointBaseline(), store = checkpointStore
                let checkpointsRoot = root.appendingPathComponent("checkpoints", isDirectory: true)
                entry.baseline = baseline
                entry.capturing += 1
                storeWork.enter()
                let turnID = user.id
                // Queued after the last turn's checkpoint, so it starts where that one ended.
                entry.checkpoints.async { [weak self, storeWork] in
                    defer { storeWork.leave() }
                    let before: AgentCheckpointStore.Snapshot
                    do { before = try store.capture(directory: captureDirectory) } catch {
                        Self.keepUnsettled(error, in: checkpointsRoot)
                        baseline.fail(error)
                        self?.baselineTaken(entry, turnID: turnID, failure: error)
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(AgentCheckpointPending(turnID: turnID, before: before))
                            .write(to: pendingDirectory.appendingPathComponent("pending-" + turnID + ".json"), options: .atomic)
                        baseline.resolve(before)
                        self?.baselineTaken(entry, turnID: turnID, failure: nil)
                    } catch {
                        Self.discard(before, store: store, in: checkpointsRoot)
                        baseline.fail(error)
                        self?.baselineTaken(entry, turnID: turnID, failure: error)
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
        if case .decide(_, let request, let decision, let answers) = request {
            guard let item = entry.snapshot.items.first(where: { $0.id == request && $0.kind == .approval }),
                  let interaction = item.interaction else {
                throw ServiceError(.badRequest, "This request is no longer pending.")
            }
            if item.isComplete {
                // The same decision again, as a retry after a lost reply, changes nothing.
                guard interaction.chosen == decision else { throw ServiceError(.badRequest, Self.settled(interaction)) }
                continuation.resume(returning: entry.snapshot)
                return
            }
            guard !entry.approving.contains(request), entry.runtime != nil else {
                throw ServiceError(.badRequest, "This request is no longer pending.")
            }
            guard let offered = interaction.decision(decision) else {
                throw ServiceError(.badRequest, "The provider didn't offer that decision.")
            }
            if let form = item.questionnaire, offered.kind == .submit {
                try form.validate(answers: answers ?? [:], cancelled: false)
            } else if answers?.isEmpty == false {
                throw ServiceError(.badRequest, "This decision takes no answers.")
            }
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
                launch.provider = providers(entry.snapshot.providerID, entry.snapshot.provider)
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
        if let files = turnAttachments, !files.attachments.isEmpty { entry.stagingAttachments[files.item] = files.attachments }
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
                case .send(_, let text, _, _, _, _, _):
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
                    } else if let handoff, invocation == nil {
                        let writer = writer, archive = earlierArchive
                        delivered = try await runBlocking {
                            writer.sync {}
                            return handoff.prompt(for: text, archive: archive)
                        }
                    } else { delivered = text }
                    try await runtime.send(text: delivered, model: model, reasoningEffort: effort, attachments: staged.filter { nativeSkill == nil || $0.attachment.id != "native-skill" })
                case .setAccess: try await accessTask?.value
                case .approve(_, let request, let allow, let always, let reason):
                    try await runtime.approve(request: request, allow: allow, always: always == true, reason: reason)
                case .answer(_, let request, let answers, let cancelled): try await runtime.answer(request: request, answers: answers, cancelled: cancelled)
                case .decide(_, let request, let decision, let answers): try await runtime.decide(request: request, decision: decision, answers: answers)
                case .interrupt: try await runtime.interrupt()
                default: break
                }
                failure = nil
            } catch { failure = error }
            queue.async { [self] in
                if let files = turnAttachments { entry.stagingAttachments[files.item] = nil }
                guard !pending.finished else { return }
                pending.finished = true
                if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                // Synchronous runtime callbacks were enqueued before this completion.
                if entry.generation == generation, entry.snapshot.status != .closed, !stopping {
                    if case .send = request { entry.submitting = false }
                    if case .approve(_, let request, _, _, _) = request { entry.approving.remove(request) }
                    if case .answer(_, let request, _, _) = request { entry.approving.remove(request) }
                    if case .decide(_, let request, _, _) = request { entry.approving.remove(request) }
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
                    } else if case .decide(_, let approval, "allowAlways", _) = request, entry.snapshot.provider == .claude,
                              let tool = entry.snapshot.items.first(where: { $0.id == approval })?.interaction?.summary,
                              AgentApprovalScope.canAlwaysAllow(tool) {
                        // Kept with the conversation, as an Always Allow answered the plain way is.
                        entry.alwaysAllowedTools.insert(tool)
                        touch(entry)
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
            entry.handoffFrom = nil
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
                let steps = agent.toolUseID.flatMap { entry.subagentSteps[$0] }
                agent.steps = steps?.total
                agent.stepsRevision = steps?.revision
                return agent
            }
            guard entry.snapshot.subagents != listed else { return }
            // A finished agent's steps are saved at once, so they outlast this server.
            for agent in listed ?? [] where agent.status != .running {
                if let id = agent.toolUseID, entry.unsavedChildren.contains(id) { saveChildren(entry, only: id) }
            }
            entry.snapshot.subagents = listed
        case .subagentSteps(let toolUseID, let items):
            guard toolUseID.utf8.count <= 1024 else { return }
            if entry.subagentSteps[toolUseID] == nil, entry.subagentSteps.count >= AgentSubagentTranscript.maxAgents,
               let oldest = entry.subagentSteps.keys.first(where: { key in
                   !(entry.snapshot.subagents ?? []).contains { $0.toolUseID == key && $0.status == .running }
               }) {
                // Saved first, so its steps stay readable.
                saveChildren(entry, only: oldest)
                entry.subagentSteps.removeValue(forKey: oldest)
            }
            var steps = entry.subagentSteps[toolUseID] ?? AgentChildTranscript(toolUseID: toolUseID, project: entry.snapshot.project)
            guard steps.absorb(items) else { return }
            entry.subagentSteps[toolUseID] = steps
            entry.unsavedChildren.insert(toolUseID)
            scheduleChildSave(entry)
            guard let index = entry.snapshot.subagents?.firstIndex(where: { $0.toolUseID == toolUseID }) else { return }
            entry.snapshot.subagents?[index].steps = steps.total
            entry.snapshot.subagents?[index].stepsRevision = steps.revision
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
            let limited = entry.snapshot.activity?.kind == .rateLimited ? entry.snapshot.activity : nil
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed, outcome: .failed)
            if let limited {
                recordRateLimit(entry, limited, message: message)
                // The turn keeps the limit; the live activity ends with it.
                entry.snapshot.activity = nil
            }
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
        snapshot.providerID = request.providerID
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
            text: "Continued from \(providers(request.providerID, request.provider).title). New messages carry on this conversation."))
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
        entry.closedAt = now()
        // A retry waits for the conversation to be reopened and asked again.
        if var turns = entry.snapshot.turns {
            for index in turns.indices { turns[index].rateLimit?.retryAt = nil }
            entry.snapshot.turns = turns
        }
        if !entry.inbox.visible.isEmpty {
            do {
                try mutateInbox(entry) { inbox in
                    inbox.paused = true
                    // Prompts not yet sent are cancelled; ones that may have reached the
                    // agent stay, paused, for review when the conversation is reopened.
                    for index in inbox.records.indices where inbox.records[index].display?.state == .queued {
                        inbox.records[index].prompt = nil; inbox.records[index].display = nil
                    }
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
            lastProviderMessage: entry.lastProviderMessage, handoffFrom: entry.handoffFrom, archived: true, closedAt: now())
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
                for folder in ["attachments", "outputs", "checkpoints", AgentChildTranscripts.folder] {
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
                let originals = ["attachments", "outputs", "checkpoints", AgentChildTranscripts.folder].map { root.appendingPathComponent($0 + "/" + session.description) } + [oldEarlier]
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
                    archive.closedAt = saved.closedAt
                    archive.turnForkPoints = entry.turnForkPoints
                    archive.forkSource = entry.forkSource; archive.forkPoint = entry.forkPoint
                    archive.lastProviderMessage = entry.lastProviderMessage
                    archive.handoffFrom = entry.handoffFrom
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

    /// Where items a conversation dropped past its size limit are kept, one JSON line each,
    /// for as long as the conversation is.
    private func earlierFile(session: SessionId) -> URL {
        let suffix = entries[session]?.snapshot.resetID.map { "-" + $0.description } ?? ""
        return root.appendingPathComponent("earlier", isDirectory: true).appendingPathComponent(session.description + suffix + ".jsonl")
    }

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
                try handle.seekToEnd()
                for line in lines { try handle.write(contentsOf: line) }
            } catch { AgentLog.error("agent earlier items not archived: \(error)") }
        }
    }

    /// A page of archived items, read on a blocking worker after earlier archive writes.
    private func earlierItems(session: SessionId, before: Int?, limit: Int) async throws -> AgentEarlierItems {
        let file = queue.sync { earlierFile(session: session) }
        let writer = writer, earlierArchive = earlierArchive
        return try await runBlocking { () throws -> AgentEarlierItems in
            writer.sync {}
            guard let lines = earlierArchive.lines(of: file) else { return AgentEarlierItems(items: [], start: 0, total: 0) }
            let end = min(before ?? lines.count, lines.count)
            var items: [AgentChatItem] = []
            var bytes = 0, encoded = 0
            var start = end
            let decoder = JSONDecoder()
            while start > 0, items.count < limit {
                let line = lines[start - 1]
                guard let item = try? decoder.decode(AgentChatItem.self, from: line) else { start -= 1; continue }
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
        // The agents' steps stay readable from their saved records.
        saveChildren(entry)
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
        item.interaction = item.interaction ?? previous?.interaction
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
            // A baseline already known to have failed says why with the turn's end, not after it.
            if let unavailable = captureCompletedTurn(entry, turnID: turns[index].userItemID), turns[index].checkpoint == nil {
                turns[index].checkpointStatus = unavailable
            }
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
                turns[index].checkpointStatus = AgentChatTurn.checkpointReady
            } else if index == turns.indices.last,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("pending-" + id + ".json")),
                      let value = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data),
                      value.turnID == id, value.before.directory == entry.directory {
                pending = value
                // Its result is recorded again from the saved baseline, as the turn ends or now.
                if turns[index].checkpointStatus != nil { turns[index].checkpointStatus = AgentChatTurn.checkpointCapturing }
            } else if turns[index].checkpointStatus?.state == .capturing {
                // Stopped before the turn's baseline was saved, or after a later turn began:
                // what the turn changed can't be told apart now.
                turns[index].checkpointStatus = .init(state: .unavailable,
                    reason: "The agent service stopped before this turn's file changes were recorded.", retryable: false)
            } else if turns[index].checkpointStatus?.retryable == true, index != turns.indices.last {
                turns[index].checkpointStatus?.retryable = false
            }
        }
        entry.snapshot.turns = turns
        if let pending {
            entry.baseline = CheckpointBaseline(pending.before)
            // Already-terminal turns do not pass through updateTurn on startup.
            if turns.last?.completedAt != nil { captureCompletedTurn(entry, turnID: pending.turnID) }
        }
    }

    /// Records the turn's result against its baseline. When the baseline is already known to
    /// have failed, returns the turn's status for the caller to apply, and records nothing.
    @discardableResult
    private func captureCompletedTurn(_ entry: Entry, turnID: String) -> AgentTurnCheckpointStatus? {
        guard let baseline = entry.baseline else { return nil }
        entry.baseline = nil
        if let unavailable = baseline.unavailable { return unavailable }
        let directory = entry.directory
        let destination = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
        entry.capturing += 1
        storeWork.enter()
        let store = checkpointStore
        let checkpointsRoot = root.appendingPathComponent("checkpoints", isDirectory: true)
        // After this turn's baseline on the same queue, which has taken it by then.
        entry.checkpoints.async { [weak self, storeWork] in
            defer { storeWork.leave() }
            guard let before = baseline.taken else {
                self?.captureFinished(entry, turnID: turnID, baseline.unavailable.map { .failure(AgentBaselineUnavailable(status: $0)) })
                return
            }
            let result: Result<AgentTurnCheckpoint, Error>
            do {
                let after: AgentCheckpointStore.Snapshot
                do { after = try store.capture(directory: directory) } catch {
                    Self.keepUnsettled(error, in: checkpointsRoot)
                    throw error
                }
                do {
                    let files = try store.files(from: before, to: after)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    // A baseline recovered from an older record finds its repository through this one.
                    var before = before
                    if before.repository == nil, before.directory == after.directory { before.repository = after.repository }
                    let record = AgentCheckpointRecord(before: before, after: after, files: files)
                    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(turnID + ".json"), options: .atomic)
                    result = .success(record.summary(id: turnID))
                } catch {
                    Self.discard(after, store: store, in: checkpointsRoot)
                    throw error
                }
            } catch {
                // Keep the durable baseline pinned so a retry or restart recovery can try again.
                AgentLog.error("agent checkpoint unavailable: \(error)")
                result = .failure(error)
            }
            self?.captureFinished(entry, turnID: turnID, result)
        }
        return nil
    }

    /// Records that taking a turn's baseline ended. Its failure, kept on the baseline, makes
    /// the turn's changes unavailable for good, as nothing marks where the turn began; the
    /// turn says so as it ends.
    private func baselineTaken(_ entry: Entry, turnID: String, failure: Error?) {
        if let failure { AgentLog.error("agent checkpoint baseline unavailable: \(failure)") }
        queue.async { entry.capturing -= 1 }
    }

    /// Records how capturing a turn's result ended: its checkpoint, or why it is unavailable,
    /// which the latest turn may try again from its baseline.
    private func captureFinished(_ entry: Entry, turnID: String, _ result: Result<AgentTurnCheckpoint, Error>?) {
        queue.async { [self] in
            entry.capturing -= 1
            guard let result, !stopping, !entry.resetting, entries[entry.snapshot.session] === entry,
                  let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turnID }) else { return }
            switch result {
            case .success(let summary):
                entry.snapshot.turns?[index].checkpoint = summary
                entry.snapshot.turns?[index].checkpointStatus = AgentChatTurn.checkpointReady
            case .failure(let failure as AgentBaselineUnavailable):
                guard entry.snapshot.turns?[index].checkpoint == nil,
                      entry.snapshot.turns?[index].checkpointStatus != failure.status else { return }
                entry.snapshot.turns?[index].checkpointStatus = failure.status
            case .failure(let error):
                let latest = index == (entry.snapshot.turns?.count ?? 0) - 1
                entry.snapshot.turns?[index].checkpointStatus = .init(state: .unavailable,
                    reason: error.localizedDescription, retryable: latest)
            }
            touch(entry)
            persist(entry)
        }
    }

    /// Records the turn's file changes again from its saved baseline, after recording them
    /// failed. Only the latest turn, once it ended, while its baseline is still pinned.
    private func retryCheckpoint(session: SessionId, turn: String) async throws -> AgentChatSnapshot {
        let pendingFile = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
            .appendingPathComponent("pending-" + turn + ".json")
        let directory = try queue.sync { () throws -> String in
            guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
            return entry.directory
        }
        let pending: AgentCheckpointPending? = try await runBlocking {
            guard let data = try? Data(contentsOf: pendingFile),
                  let value = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data),
                  value.turnID == turn, value.before.directory == directory,
                  GitCommand().optionalText(directory, ["rev-parse", "--verify", "--quiet", value.before.reference]) != nil else { return nil }
            return value
        }
        return try queue.sync { () throws -> AgentChatSnapshot in
            guard !stopping, let entry = entries[session], !entry.resetting, entry.snapshot.status != .closed else {
                throw ServiceError(.badRequest, "The agent session is closed or the server is stopping")
            }
            guard let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turn }),
                  let status = entry.snapshot.turns?[index].checkpointStatus, status.state == .unavailable,
                  entry.snapshot.turns?[index].checkpoint == nil else {
                throw ServiceError(.badRequest, "This turn's file changes aren't waiting to be recorded again.")
            }
            guard status.retryable == true, index == (entry.snapshot.turns?.count ?? 0) - 1,
                  entry.snapshot.turns?[index].completedAt != nil, !entry.submitting,
                  entry.baseline == nil, entry.capturing == 0 else {
                throw AgentRuntimeError("Recording can be tried again only for the latest finished turn.")
            }
            guard !restoreHolds(entry), entry.reverts == 0 else {
                throw AgentRuntimeError("Files are being restored in this folder. Try again when the restore finishes.")
            }
            guard let pending else {
                entry.snapshot.turns?[index].checkpointStatus = .init(state: .unavailable,
                    reason: "The turn's original baseline is gone, so its file changes can't be recorded.", retryable: false)
                touch(entry)
                persist(entry)
                throw AgentRuntimeError("The turn's original baseline is gone, so its file changes can't be recorded.")
            }
            entry.snapshot.turns?[index].checkpointStatus = AgentChatTurn.checkpointCapturing
            entry.baseline = CheckpointBaseline(pending.before)
            captureCompletedTurn(entry, turnID: turn)
            touch(entry)
            return entry.snapshot
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
                    // A turn the user was stopping stays stopped.
                    entry.resumeAfterRestart = entry.interrupting == nil && !entry.archived
                        && AgentRestartResume.resumes(entry.snapshot, handoff: entry.handoffFrom != nil)
                    interrupted(entry, message: entry.resumeAfterRestart ? AgentRestartResume.stoppedNotice
                        : AgentRestartResume.interruptedNotice)
                }
                entry.submitting = false
                entry.approving.removeAll()
                entry.interrupting = nil
                entry.accessTask = nil
                clearDeferredEvents(entry)
                persist(entry)
                saveChildren(entry)
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
        // A closed conversation keeps its outputs: it can be reopened.
        let kept = Set(saved.snapshot.items.lazy
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
        // A ref another conversation's record also pins, as an archive's copy, stays its.
        let shared = refsPinned(excluding: session)
        if shared == nil { pinned += 1 }
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
            guard let shared else { continue }
            // Each ref on its own, so one Git can't remove yet doesn't keep the other.
            let failures = refs.filter { !shared.contains($0.reference) }.compactMap { ref -> Error? in
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
                      root.appendingPathComponent("inbox/" + session + ".json"),
                      root.appendingPathComponent(AgentChildTranscripts.folder, isDirectory: true).appendingPathComponent(session, isDirectory: true)]
        // Other stores' parts go too; one that fails keeps the record for the next start.
        var failedCleanups = 0
        for cleanup in deletionCleanups {
            do { try cleanup(snapshot.session) } catch {
                failedCleanups += 1
                AgentLog.error("deleting conversation \(session): a store kept its part for later: \(error)")
            }
        }
        // A checkpoint whose ref remains keeps its record, and so its folder.
        let remaining = (pinned > 0 ? others : [checkpoints] + others).filter { !Self.removeIfPresent($0) }.count + (pinned > 0 ? 1 : 0) + failedCleanups
        guard remaining == 0 else {
            AgentLog.error("deleting conversation \(session) continues at the next start: \(remaining) of its files remain")
            return
        }
        _ = Self.removeIfPresent(record)
        let deleted = conversationDeleted, id = snapshot.session
        callbacks.async { deleted(id) }
    }

    /// The refs every other conversation's checkpoint records pin, or nil when one can't be
    /// read, so nothing it may pin is removed.
    private func refsPinned(excluding session: String) -> Set<String>? {
        let checkpoints = root.appendingPathComponent("checkpoints", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil) else {
            return (try? Self.isPresent(checkpoints)) == false ? [] : nil
        }
        var pinned = Set<String>()
        for folder in folders where folder.lastPathComponent != session && !folder.lastPathComponent.hasPrefix(".") {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let pins = try? JSONDecoder().decode(CheckpointPins.self, from: data) else { return nil }
                pinned.formUnion(pins.refs.map(\.reference))
            }
        }
        return pinned
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
                          lastProviderMessage: entry.lastProviderMessage, handoffFrom: entry.handoffFrom,
                          archived: entry.archived ? true : nil,
                          closedAt: entry.snapshot.status == .closed ? entry.closedAt : nil,
                          resumeAfterRestart: entry.resumeAfterRestart ? true : nil)
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
    private var failure: AgentTurnCheckpointStatus?
    /// Why it couldn't be taken, once that is known.
    var unavailable: AgentTurnCheckpointStatus? { lock.withLock { failure } }

    /// Settles it as not taken, for `error`'s reason.
    func fail(_ error: Error) {
        let untracked = error as? AgentCheckpointUnavailable == .notRepository
        lock.withLock {
            if !settled { failure = .init(state: untracked ? .untracked : .unavailable, reason: error.localizedDescription, retryable: false) }
        }
        resolve(nil)
    }

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

/// A turn's baseline that couldn't be taken, with the status the turn shows for it.
struct AgentBaselineUnavailable: Error {
    let status: AgentTurnCheckpointStatus
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
        case .updateQueued(_, let id, let edit, let revision):
            try mutateInbox(entry) { try $0.update(id, revision: revision, edit: edit) }
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
              !entry.submitting, entry.deliveryID == nil, !restoreHolds(entry),
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
        if restoreHolds(entry) { throw AgentRuntimeError("Files are being restored in this folder. The prompt waits until the restore finishes.") }
        if entry.snapshot.status == .working {
            guard prompt.model == entry.snapshot.model, prompt.effort == entry.snapshot.reasoningEffort,
                  Self.keepsProvider(prompt, entry.snapshot), prompt.planMode == (entry.snapshot.planMode == true) else {
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
                        case .success(let snapshot) where snapshot.turns?.last(where: { $0.userItemID == attemptID })?.rateLimit != nil:
                            // A usage limit ended its turn: the turn keeps the prompt and its retry,
                            // so nothing is left to review here.
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
                                    provider: prompt.provider, attachments: prompt.attachments, providerID: prompt.providerID),
                              continuation: delivered, deliveryID: attemptID)
                } catch { delivered.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Child agents' steps

extension AgentSessions {
    /// A page of an agent's steps: from memory while its provider runs, else from its saved
    /// record, else a background shell's output; `unavailable` when none of them has it.
    private func childSteps(session: SessionId, toolUseID: String, before: Int?,
                            limit: Int = AgentSubagentSteps.maxItems) async throws -> AgentSubagentSteps {
        enum Source { case kept(AgentChildTranscript), saved(ProjectId, listed: Bool), shell(AgentChatItem, AgentSubagent) }
        let source = try queue.sync { () throws -> Source in
            guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
            if let steps = entry.subagentSteps[toolUseID] { return .kept(steps) }
            if before == nil, let task = entry.snapshot.subagents?.first(where: { $0.toolUseID == toolUseID && $0.agentType == "Shell" }),
               let item = entry.snapshot.items.last(where: { $0.id == toolUseID }) { return .shell(item, task) }
            return .saved(entry.snapshot.project, listed: entry.snapshot.subagents?.contains { $0.toolUseID == toolUseID } == true)
        }
        switch source {
        case .kept(let steps):
            return steps.page(before: before, limit: limit)
        case .shell(let item, let task):
            let step = try await runBlocking { AgentBackgroundShell.step(item, task: task) }
            return AgentSubagentSteps(toolUseID: toolUseID, items: [step])
        case .saved(let project, let listed):
            let root = root, writer = writer
            let saved = try await runBlocking { () -> AgentChildTranscript? in
                writer.sync {}
                return AgentChildTranscripts.load(root: root, session: session, toolUseID: toolUseID, project: project)
            }
            if let saved { return saved.page(before: before, limit: limit) }
            // A listed agent that took no step yet has none to show; any other was never saved.
            return AgentSubagentSteps(toolUseID: toolUseID, items: [], unavailable: listed ? nil : true)
        }
    }

    /// Saves the steps that changed since they were last saved: of every agent, or of `only`.
    /// On the sessions queue; the files are written in order on the writer.
    private func saveChildren(_ entry: Entry, only: String? = nil) {
        let ids = only.map { entry.unsavedChildren.contains($0) ? [$0] : [] } ?? Array(entry.unsavedChildren)
        guard !ids.isEmpty, entries[entry.snapshot.session] === entry else { return }
        entry.unsavedChildren.subtract(ids)
        let records = ids.compactMap { entry.subagentSteps[$0] }
        let root = root, session = entry.snapshot.session
        write {
            for record in records {
                do { try AgentChildTranscripts.save(record, root: root, session: session) }
                catch { AgentLog.error("agent steps not saved: \(error)") }
            }
        }
    }

    /// Saves changed steps a second after the first change, so a busy agent is written
    /// about once a second rather than at every step.
    private func scheduleChildSave(_ entry: Entry) {
        guard !entry.childSaveScheduled else { return }
        entry.childSaveScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak entry] in
            guard let self, let entry else { return }
            entry.childSaveScheduled = false
            self.saveChildren(entry)
        }
    }
}

/// Deletes one store's part of a conversation being permanently deleted, by the retention
/// rule or a confirmed delete, as subagent transcripts kept beside the record. It runs on
/// the sessions' writer, after the conversation's own checkpoints and files are handled and
/// before its record goes; one that throws keeps the record, so the deletion is tried again
/// at the next start. Shared resources must stay while another conversation references them.
typealias AgentDeletionCleanup = @Sendable (SessionId) throws -> Void

// MARK: Kept conversations

extension AgentSessions {
    func library(_ request: AgentConversationLibraryRequest) async throws -> AgentConversationLibraryReply {
        try request.validate()
        switch request {
        case .list(let project):
            return .list(queue.sync {
                entries.values.filter { $0.snapshot.status == .closed && !$0.resetting && (project == nil || $0.snapshot.project == project) }
                    .map(savedConversation).sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
            })
        case .archive(let session):
            return .snapshot(try queue.sync {
                guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                guard entry.snapshot.status != .closed else { return entry.snapshot }
                guard !stopping, !entry.resetting, entry.reverts == 0, !entry.submitting, entry.deliveryID == nil,
                      entry.snapshot.status == .idle || entry.snapshot.status == .failed,
                      entry.inbox.visible.allSatisfy({ $0.state != .queued && $0.state != .delivering }),
                      entry.snapshot.subagents?.contains(where: { $0.status == .running }) != true,
                      !importing.contains(session) else {
                    throw AgentRuntimeError("Stop active work and remove queued prompts before archiving. The conversation is kept as it is.")
                }
                close(entry)
                return entry.snapshot
            })
        case .reopen(let session):
            return .snapshot(try queue.sync {
                guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
                guard entry.snapshot.status == .closed else { return entry.snapshot }
                guard !entry.resetting else { throw AgentRuntimeError("The conversation is being cleared. Try again shortly.") }
                reopen(entry)
                return entry.snapshot
            })
        case .delete(let session, _):
            let (saved, file) = try queue.sync { () throws -> (Saved, URL) in
                guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
                guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
                guard entry.snapshot.status == .closed, !entry.resetting, entry.reverts == 0, entry.runtime == nil,
                      !entry.submitting, !importing.contains(session) else {
                    throw AgentRuntimeError("Close or archive this conversation before deleting it.")
                }
                // Gone at once: nothing reads or writes it after this.
                entries.removeValue(forKey: session)
                return (savedRecord(entry), root.appendingPathComponent(session.description + ".json"))
            }
            try await written { [self] in removeConversation(saved, file: file) }
            return .deleted(session)
        }
    }

    private func savedConversation(_ entry: Entry) -> AgentSavedConversation {
        let first = entry.snapshot.items.first { $0.kind == .user && !$0.isProviderTurn }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = first.isEmpty ? entry.snapshot.provider.name + " conversation" : String(first.prefix(120))
        return AgentSavedConversation(session: entry.snapshot.session, project: entry.snapshot.project, provider: entry.snapshot.provider,
            title: title, origin: entry.archived ? .cleared : .closed, closedAt: entry.closedAt,
            messages: entry.snapshot.items.filter { $0.kind == .user || $0.kind == .assistant }.count,
            expiresAt: entry.closedAt.flatMap(retention.expiry(closedAt:)))
    }

    /// The record `persist` writes for `entry`.
    private func savedRecord(_ entry: Entry) -> Saved {
        let retained = Set(entry.snapshot.items.lazy.filter { $0.kind == .user }.map(\.id))
        return Saved(turnForkPoints: entry.turnForkPoints.filter { retained.contains($0.key) },
                     alwaysAllowedTools: entry.alwaysAllowedTools.isEmpty ? nil : entry.alwaysAllowedTools.sorted(),
                     snapshot: entry.snapshot, directory: entry.directory, hasSuccessfulTurn: entry.hasSuccessfulTurn,
                     forkSource: entry.forkSource, forkPoint: entry.forkPoint,
                     lastProviderMessage: entry.lastProviderMessage, handoffFrom: entry.handoffFrom,
                     archived: entry.archived ? true : nil,
                     closedAt: entry.snapshot.status == .closed ? entry.closedAt : nil)
    }

    /// Makes a closed conversation usable again under its own identity. Its provider
    /// conversation resumes with the next message; prompts that may have reached the agent
    /// stay paused for review, and the acceptance ledger still refuses replays.
    private func reopen(_ entry: Entry) {
        entry.snapshot.status = .idle
        entry.closedAt = nil
        entry.deliveryCancelled = false
        if !entry.inbox.records.isEmpty {
            do { try mutateInbox(entry) { $0.recover() } }
            catch { entry.inboxError = error.localizedDescription }
        }
        entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: entry.inbox.visible.isEmpty
            ? "Conversation reopened." : "Conversation reopened. Review the paused prompts before sending them again."), entry: entry))
        touch(entry)
        persist(entry)
    }
}

// MARK: Usage limits

extension AgentSessions {
    /// Keeps the provider's usage limit on the turn it stopped, with the prompt's retry identity.
    private func recordRateLimit(_ entry: Entry, _ activity: AgentChatActivity, message: String) {
        guard let index = entry.snapshot.turns?.indices.last, let turn = entry.snapshot.turns?[index],
              entry.snapshot.items.contains(where: { $0.id == turn.userItemID && $0.kind == .user && !$0.isProviderTurn }) else { return }
        let limit = AgentTurnRateLimit(resetsAt: activity.resumesAt, message: String((activity.message ?? message).prefix(1024)),
            retryPromptID: AgentTurnRateLimit.retryPromptID(session: entry.snapshot.session, turn: turn.userItemID))
        entry.snapshot.turns?[index].rateLimit = limit
    }

    private func scheduleRetry(_ entry: Entry, turn: String, enabled: Bool) throws {
        guard let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turn }),
              let limit = entry.snapshot.turns?[index].rateLimit else {
            throw ServiceError(.badRequest, "That turn wasn't stopped by a usage limit.")
        }
        if enabled {
            guard limit.retried != true else { throw ServiceError(.badRequest, "That prompt was already sent again.") }
            guard let resetsAt = limit.resetsAt else {
                throw ServiceError(.badRequest, "The provider didn't say when the limit resets. Retry it yourself later.")
            }
            entry.snapshot.turns?[index].rateLimit?.retryAt = resetsAt
        } else {
            entry.snapshot.turns?[index].rateLimit?.retryAt = nil
        }
        touch(entry)
        persist(entry)
        armRetries(entry)
    }

    /// Wakes when the earliest scheduled retry of `entry` is due.
    private func armRetries(_ entry: Entry) {
        guard let due = entry.snapshot.turns?.compactMap({ $0.rateLimit?.retried == true ? nil : $0.rateLimit?.retryAt }).min() else { return }
        let delay = max(0, due.timeIntervalSince(now()))
        queue.asyncAfter(deadline: .now() + min(delay, 365 * 86_400)) { [weak self] in
            guard let self, !self.stopping else { return }
            Task { await self.fireDueRetries() }
        }
    }

    /// Sends again every prompt whose scheduled retry is due by the injected clock, and
    /// waits for each submission. Runs from the retry timers; tests call it directly.
    func fireDueRetries() async {
        let due: [(SessionId, String)] = queue.sync {
            guard !stopping else { return [] }
            let now = now()
            return entries.values.filter { $0.snapshot.status != .closed }.flatMap { entry in
                (entry.snapshot.turns ?? []).compactMap { turn -> (SessionId, String)? in
                    guard let limit = turn.rateLimit, limit.retried != true, let at = limit.retryAt, at <= now else { return nil }
                    return (entry.snapshot.session, turn.userItemID)
                }
            }
        }
        for (session, turn) in due {
            do { _ = try await retryRateLimitedTurn(session: session, turn: turn) }
            catch {
                AgentLog.error("scheduled retry of \(session) not sent: \(error)")
                queue.sync {
                    guard let entry = entries[session], let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turn }) else { return }
                    entry.snapshot.turns?[index].rateLimit?.retryAt = nil
                    entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice,
                        text: "The scheduled retry wasn't sent: " + error.localizedDescription), entry: entry))
                    touch(entry)
                    persist(entry)
                }
            }
        }
    }

    /// Submits the stopped turn's prompt again under the turn's retry identity. The prompt
    /// ledger refuses a second delivery, so a manual retry racing a scheduled one, or a
    /// client retrying after a lost reply, sends it once.
    private func retryRateLimitedTurn(session: SessionId, turn: String) async throws -> AgentChatSnapshot {
        let found = try queue.sync { () throws -> (AgentChatItem, AgentTurnRateLimit, AgentChatSnapshot) in
            guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
            guard let limit = entry.snapshot.turns?.first(where: { $0.userItemID == turn })?.rateLimit else {
                throw ServiceError(.badRequest, "That turn wasn't stopped by a usage limit.")
            }
            guard let item = entry.snapshot.items.first(where: { $0.id == turn && $0.kind == .user }) else {
                throw ServiceError(.badRequest, "That prompt is no longer kept in the conversation.")
            }
            return (item, limit, entry.snapshot)
        }
        let (item, limit, snapshot) = found
        if limit.retried == true { return snapshot }
        let folder = root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(session.description, isDirectory: true)
            .appendingPathComponent(AgentToolImages.directoryName(item: item.id), isDirectory: true)
        let descriptors = item.attachments ?? []
        let attachments = try await runBlocking { try descriptors.map { try AgentAttachments.retrieve($0, root: folder) } }
        let prompt = AgentPrompt(id: limit.retryPromptID, text: item.text, model: snapshot.model, effort: snapshot.reasoningEffort,
                                 provider: snapshot.provider, planMode: snapshot.planMode == true, attachments: attachments)
        _ = try await handle(.submit(session: session, prompt: prompt))
        return queue.sync {
            guard let entry = entries[session] else { return snapshot }
            if let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turn }) {
                entry.snapshot.turns?[index].rateLimit?.retried = true
                entry.snapshot.turns?[index].rateLimit?.retryAt = nil
                touch(entry)
                persist(entry)
            }
            return entry.snapshot
        }
    }

    /// Why a settled request can't take another decision.
    static func settled(_ interaction: AgentApprovalRequest) -> String {
        switch interaction.outcome {
        case .expired?: "The agent that asked has ended, so this request expired."
        case .resolvedElsewhere?: "This request was settled elsewhere."
        case .ended?: "The response ended before this request was answered."
        default: "This request was already answered."
        }
    }
}
