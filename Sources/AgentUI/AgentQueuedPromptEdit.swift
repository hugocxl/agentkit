import AgentCore
import AppKit
import Combine

/// An edit of a queued prompt: its whole new text, settings and attachments, made against
/// the revision the user started from. It is kept until the server confirms it.
struct AgentQueuedPromptEdit: Equatable {
    enum Attachment: Equatable {
        /// One the queued prompt holds on the server, by its descriptor.
        case existing(AgentChatAttachmentDescriptor)
        /// One added in this edit, with its bytes.
        case added(AgentChatAttachment)

        var id: String {
            switch self {
            case .existing(let descriptor): return descriptor.id
            case .added(let attachment): return attachment.id
            }
        }
        var descriptor: AgentChatAttachmentDescriptor {
            switch self {
            case .existing(let descriptor): return descriptor
            case .added(let attachment): return attachment.descriptor
            }
        }
    }

    /// Where the queued prompt stands against this edit, on the server.
    enum Standing: Equatable {
        /// The server holds exactly this edit already, as when its reply was lost.
        case applied
        /// Still the version this edit started from.
        case unchanged(AgentQueuedPrompt)
        /// Someone changed it since: another client, or a move that bumped its revision.
        case changed(AgentQueuedPrompt)
        /// Its delivery began, so it can no longer change.
        case started
        /// It left the queue: delivered, removed, or the conversation was cleared.
        case gone
    }

    let promptID: String
    var baseRevision: UInt64
    var text: String
    var attachments: [Attachment]
    /// Nil keeps the prompt's model, reasoning effort and plan mode.
    var settings: AgentQueuedSettings?
    private(set) var originalAttachmentIDs: [String]

    init(prompt: AgentQueuedPrompt) {
        promptID = prompt.id
        baseRevision = prompt.revision
        text = prompt.text
        attachments = prompt.attachments.map { .existing($0) }
        originalAttachmentIDs = prompt.attachments.map(\.id)
    }

    var attachmentsChanged: Bool { attachments.map(\.id) != originalAttachmentIDs }
    /// No text and no attachments: nothing a prompt could send.
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
    var byteCount: Int { attachments.reduce(0) { $0 + $1.descriptor.byteCount } }

    /// The revision-checked request that applies this edit whole or not at all.
    func request(session: SessionId) -> AgentChatRequest {
        .updateQueued(session: session, id: promptID, edit: AgentQueuedEdit(text: text, settings: settings, attachments: attachments.map {
            switch $0 {
            case .existing(let descriptor): return .keep(id: descriptor.id)
            case .added(let attachment): return .add(attachment)
            }
        }), expectedRevision: baseRevision)
    }

    /// The request a server that predates attachment edits understands, when attachments are unchanged.
    func legacyRequest(session: SessionId) -> AgentChatRequest? {
        guard !attachmentsChanged else { return nil }
        return .editQueued(session: session, id: promptID, text: text, expectedRevision: baseRevision, settings: settings)
    }

    mutating func add(_ added: [AgentChatAttachment]) throws {
        let next = attachments + added.map { .added($0) }
        try Self.check(next)
        attachments = next
    }

    mutating func remove(_ id: String) { attachments.removeAll { $0.id == id } }

    /// Puts `replacement` where `id` was, so the order of the prompt's attachments holds.
    mutating func replace(_ id: String, with replacement: AgentChatAttachment) throws {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { throw ModelError("That attachment is no longer in this prompt.") }
        var next = attachments
        next[index] = .added(replacement)
        try Self.check(next)
        attachments = next
    }

    private static func check(_ attachments: [Attachment]) throws {
        guard attachments.count <= AgentChatAttachment.maxCount,
              attachments.reduce(0, { $0 + $1.descriptor.byteCount }) <= AgentChatAttachment.maxTotalBytes else {
            throw ModelError("Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB.")
        }
    }

    func standing(in snapshot: AgentChatSnapshot) -> Standing {
        guard let prompt = snapshot.queuedPrompts?.first(where: { $0.id == promptID }) else { return .gone }
        if prompt.state == .delivering { return .started }
        if prompt.revision == baseRevision { return .unchanged(prompt) }
        if prompt.text == text, prompt.attachments.map(\.id) == attachments.map(\.id) { return .applied }
        return .changed(prompt)
    }

    /// Bases this edit on `latest`, keeping the user's text and settings. Attachments the
    /// latest version no longer holds are dropped; their names are returned.
    mutating func rebase(on latest: AgentQueuedPrompt) -> [String] {
        let held = Set(latest.attachments.map(\.id))
        let dropped = attachments.filter {
            if case .existing(let descriptor) = $0 { return !held.contains(descriptor.id) }
            return false
        }
        attachments.removeAll { dropped.contains($0) }
        baseRevision = latest.revision
        originalAttachmentIDs = latest.attachments.map(\.id)
        return dropped.map(\.descriptor.name)
    }
}

/// What went wrong with a queued prompt's edit, and what the user can do with it.
struct AgentQueueEditProblem: Equatable {
    enum Choice: Equatable { case retry, review, copy, stash, keep, discard }
    var title: String
    var message: String
    var choices: [Choice]
    var edit: AgentQueuedPromptEdit
}

extension AgentQueueEditProblem.Choice {
    var title: String {
        switch self {
        case .retry: return "Try Again"
        case .review: return "Review My Edit"
        case .copy: return "Copy My Edit"
        case .stash: return "Stash My Edit"
        case .keep: return "Keep for Later"
        case .discard: return "Discard My Edit"
        }
    }
}

/// The queued prompt editor: text, attachments and settings, in a sheet. Cancelling never
/// changes the queued prompt or the composer's draft.
@MainActor
final class AgentQueuedPromptEditor {
    let sheet: AgentTextEditorSheet
    let strip = AgentAttachmentStrip(frame: .zero)
    let add = NSButton(title: "Add Files…", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private(set) var edit: AgentQueuedPromptEdit
    private let theme: AgentTheme
    private let fetch: AgentAttachmentCache.Fetch?
    private var importTask: Task<Void, Never>?
    private(set) var preview: AgentFilePreviewWindow?
    private let target = ActionTarget()

    init(edit: AgentQueuedPromptEdit, detail: String, theme: AgentTheme, attachments allowed: Bool,
         fetch: AgentAttachmentCache.Fetch?) {
        self.edit = edit
        self.theme = theme
        self.fetch = fetch
        sheet = AgentTextEditorSheet(title: "Edit queued prompt", detail: detail, text: edit.text, theme: theme, showsSettings: true)
        sheet.settings.state = edit.settings == nil ? .off : .on
        guard allowed, let original = sheet.alert.accessoryView else { return }
        let stripHeight: CGFloat = 76, row: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: original.frame.width, height: original.frame.height + stripHeight + row + 4))
        original.frame.origin = .zero
        container.addSubview(original)
        strip.frame = NSRect(x: 0, y: original.frame.height + row + 4, width: original.frame.width, height: stripHeight)
        add.frame = NSRect(x: 0, y: original.frame.height + 2, width: 110, height: row)
        add.bezelStyle = .rounded
        add.setAccessibilityLabel("Add attachments to the queued prompt")
        status.frame = NSRect(x: 116, y: original.frame.height + 2, width: original.frame.width - 116, height: row)
        status.font = AppFont.small
        status.textColor = theme.fgMuted
        status.maximumNumberOfLines = 2
        for view in [strip, add, status] as [NSView] { container.addSubview(view) }
        sheet.alert.accessoryView = container
        target.action = { [weak self] in self?.chooseFiles(replacing: nil) }
        add.target = target
        add.action = #selector(ActionTarget.run)
        strip.onRemove = { [weak self] id in
            self?.edit.remove(id)
            self?.refresh()
        }
        strip.onReplace = { [weak self] id in self?.chooseFiles(replacing: id) }
        strip.onPreview = { [weak self] id in self?.showPreview(id) }
        refresh()
    }

    /// The attachments as the strip shows them.
    private func refresh() {
        strip.update(edit.attachments.map { attachment in
            switch attachment {
            case .existing(let descriptor):
                return AgentDraftAttachment(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, data: Data(), byteCount: descriptor.byteCount)
            case .added(let added):
                return AgentDraftAttachment(id: added.id, name: added.name, mimeType: added.mimeType, data: added.data)
            }
        }, theme: theme)
        status.stringValue = edit.attachments.isEmpty ? "No attachments" : ""
    }

    /// Adds files, or puts one in place of `id`.
    func chooseFiles(replacing id: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = id == nil
        panel.prompt = id == nil ? "Attach" : "Replace"
        panel.beginSheetModal(for: sheet.alert.window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(urls: panel.urls, replacing: id)
        }
    }

    func attach(urls: [URL], replacing id: String?) {
        importTask?.cancel()
        status.stringValue = "Preparing attachments…"
        importTask = Task { [weak self] in
            do {
                let loaded = try await AgentAttachmentImporter.load(urls: urls)
                guard let self, !Task.isCancelled else { return }
                try self.apply(loaded.map { AgentChatAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }, replacing: id)
            } catch is CancellationError {
            } catch { self?.status.stringValue = error.localizedDescription }
        }
    }

    func apply(_ attachments: [AgentChatAttachment], replacing id: String?) throws {
        if let id, let first = attachments.first {
            try edit.replace(id, with: first)
        } else {
            try edit.add(attachments)
        }
        refresh()
    }

    private func showPreview(_ id: String) {
        guard let attachment = edit.attachments.first(where: { $0.id == id }) else { return }
        let promptID = edit.promptID
        let fetch: AgentAttachmentCache.Fetch
        switch attachment {
        case .added(let added): fetch = { _, _ in added.data }
        case .existing:
            guard let server = self.fetch else { status.stringValue = "This attachment can't be previewed here."; return }
            fetch = server
        }
        preview?.close()
        let window = AgentFilePreviewWindow(item: promptID, attachment: attachment.descriptor, fetch: fetch, theme: theme)
        preview = window
        window.showWindow(nil)
    }

    /// Shows the sheet; the edit comes back on Save, nil on Cancel.
    func present(in window: NSWindow, current settings: AgentQueuedSettings) async -> AgentQueuedPromptEdit? {
        await withCheckedContinuation { continuation in
            sheet.present(in: window) { [self] response, text, useSettings in
                importTask?.cancel()
                preview?.close()
                guard response == .alertFirstButtonReturn else { continuation.resume(returning: nil); return }
                var result = edit
                result.text = text
                result.settings = useSettings ? settings : nil
                continuation.resume(returning: result)
            }
        }
    }

    func follow(_ theme: AgentTheme) { sheet.follow(theme); strip.updateTheme(theme) }
    func close() { importTask?.cancel(); preview?.close(); sheet.close() }

    private final class ActionTarget: NSObject {
        var action: (() -> Void)?
        @objc func run() { action?() }
    }
}

extension AgentPaneController {
    /// The settings a queued prompt takes when its editor's "Use current" box is on.
    var currentQueuedSettings: AgentQueuedSettings {
        .init(model: effectiveModel, effort: reasoningEffort, planMode: snapshot?.planMode == true)
    }

    /// Opens a queued prompt's editor. An edit the server has not confirmed reopens as it
    /// was left, on the version now queued.
    func editQueued(_ prompt: AgentQueuedPrompt) {
        guard !disposed, queueEditor == nil, composerWork.queueEditTask == nil else { return }
        var edit = AgentQueuedPromptEdit(prompt: prompt)
        var detail = prompt.state == .uncertain || prompt.state == .failed
            ? "The earlier delivery may have reached the agent. Saving does not send it again."
            : "Saving does not send it immediately."
        if let pending = composerWork.queueEdit, pending.promptID == prompt.id {
            edit = pending
            let dropped = edit.baseRevision == prompt.revision ? [] : edit.rebase(on: prompt)
            detail = "Your unsaved edit is restored." + (dropped.isEmpty ? "" : " No longer attached: " + dropped.joined(separator: ", ") + ".")
        }
        openQueueEditor(edit, detail: detail)
    }

    func openQueueEditor(_ edit: AgentQueuedPromptEdit, detail: String) {
        let settings = currentQueuedSettings
        if let present = composerWork.presentQueueEdit {
            Task { [weak self] in
                let result = await present(edit, detail)
                guard let self, !self.disposed else { return }
                self.finishQueueEditor(edit, result: result)
            }
            return
        }
        guard let window = surface.window else { return }
        let editor = AgentQueuedPromptEditor(edit: edit, detail: detail, theme: surface.theme,
                                             attachments: capabilities.contains(.attachments), fetch: surface.fetchAttachment)
        queueEditor = editor
        Task { [weak self] in
            let result = await editor.present(in: window, current: settings)
            guard let self else { return }
            if self.queueEditor === editor { self.queueEditor = nil }
            guard !self.disposed else { return }
            self.finishQueueEditor(edit, result: result)
        }
    }

    private func finishQueueEditor(_ original: AgentQueuedPromptEdit, result: AgentQueuedPromptEdit?) {
        guard let result else {
            // Cancelled: an edit kept from a failed save is the user's to discard.
            if composerWork.queueEdit?.promptID == original.promptID { composerWork.queueEdit = nil }
            return
        }
        saveQueueEdit(result)
    }

    /// Saves `edit` against its base revision. The edit stays here until the server
    /// confirms it, so a failure or a lost reply never loses what the user wrote.
    func saveQueueEdit(_ edit: AgentQueuedPromptEdit) {
        guard !disposed, composerWork.queueEditTask == nil else { return }
        composerWork.queueEdit = edit
        if edit.isEmpty {
            composerWork.queueEditTask = Task { [weak self] in
                guard let self else { return }
                defer { self.composerWork.queueEditTask = nil }
                if await self.confirm("Remove this queued prompt?",
                                      "It has no text or attachments left. Removing it takes it out of the queue; nothing is sent.", "Remove"),
                   !self.disposed {
                    self.composerWork.queueEdit = nil
                    self.run(.removeQueued(session: self.session, id: edit.promptID, expectedRevision: edit.baseRevision))
                } else if !self.disposed {
                    self.showNotice("A queued prompt needs text or an attachment. Your edit is kept; edit the prompt again to finish it.", kind: .warning)
                }
            }
            return
        }
        let generation = connectionGeneration
        let session = session
        updateControls()
        composerWork.queueEditTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: AgentChatSnapshot
                do {
                    result = try await self.request(edit.request(session: session))
                } catch where agentErrorCode(error) == .unsupported {
                    guard let legacy = edit.legacyRequest(session: session) else {
                        throw ModelError(self.backendAdvice.cannot("change a queued prompt's attachments"))
                    }
                    result = try await self.request(legacy)
                }
                self.composerWork.queueEditTask = nil
                guard !self.disposed else { return }
                if self.composerWork.queueEdit == edit { self.composerWork.queueEdit = nil }
                if generation == self.connectionGeneration { self.accept(result, generation: generation) }
                self.updateControls()
            } catch {
                guard !self.disposed else { self.composerWork.queueEditTask = nil; return }
                let next = await self.recoverQueueEdit(edit, error: error)
                self.composerWork.queueEditTask = nil
                self.updateControls()
                next?()
            }
        }
    }

    /// Learns where the prompt stands now and lets the user decide what becomes of their edit.
    /// Nothing here sends the prompt, and the composer's draft is never touched.
    /// Returns what to do once the failed save is over, such as saving again.
    private func recoverQueueEdit(_ edit: AgentQueuedPromptEdit, error: Error) async -> (() -> Void)? {
        let latest = try? await request(.read(session: session))
        guard !disposed else { return nil }
        if let latest { accept(latest, generation: connectionGeneration, authoritative: true) }
        var problem = AgentQueueEditProblem(title: "Your queued prompt edit wasn't saved",
                                            message: error.localizedDescription + " Your edit is kept.",
                                            choices: [.retry, .copy, .stash, .keep], edit: edit)
        switch latest.map({ edit.standing(in: $0) }) {
        case .applied?:
            // The server took it and only the reply was lost.
            composerWork.queueEdit = nil
            showNotice("Saved the queued prompt.", kind: .info)
            return nil
        case .unchanged(_)?, nil: break
        case .changed(let prompt)?:
            problem.title = "This queued prompt changed elsewhere"
            problem.message = "The queue now holds a newer version: “\(prompt.text.prefix(120))”. It stays as it is unless you save your edit over it."
            problem.choices = [.review, .copy, .stash, .discard]
        case .started?:
            problem.title = "This prompt is already being sent"
            problem.message = "It can no longer change. Copy or stash your edit to use it in another message."
            problem.choices = [.copy, .stash, .discard]
        case .gone?:
            problem.title = "This prompt is no longer queued"
            problem.message = "It was sent, removed or cleared. Copy or stash your edit to use it in another message."
            problem.choices = [.copy, .stash, .discard]
        }
        let choice = await (composerWork.resolveQueueEdit ?? presentQueueEditProblem)(problem)
        guard !disposed else { return nil }
        switch choice {
        case .retry:
            // The same base revision: if the first try did reach the server, this one is
            // refused rather than applied twice, and the prompt is never sent by it.
            return { [weak self] in self?.saveQueueEdit(edit) }
        case .review:
            guard let prompt = snapshot?.queuedPrompts?.first(where: { $0.id == edit.promptID }) else { return nil }
            var rebased = edit
            let dropped = rebased.rebase(on: prompt)
            composerWork.queueEdit = rebased
            return { [weak self] in
                self?.openQueueEditor(rebased, detail: "Saving replaces the version now queued with your edit."
                    + (dropped.isEmpty ? "" : " No longer attached: " + dropped.joined(separator: ", ") + "."))
            }
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(edit.text, forType: .string)
            composerWork.queueEdit = nil
            showNotice("Copied your edit. The queued prompt is unchanged.", kind: .info)
        case .stash:
            composerWork.queueEdit = nil
            stashQueueEdit(edit)
        case .keep:
            showNotice("Your edit is kept. Edit the queued prompt again to finish it.", kind: .info)
        case .discard:
            composerWork.queueEdit = nil
        }
        return nil
    }

    private func presentQueueEditProblem(_ problem: AgentQueueEditProblem) async -> AgentQueueEditProblem.Choice {
        guard let window = surface.window else { return problem.choices.contains(.keep) ? .keep : .copy }
        let alert = NSAlert()
        alert.messageText = problem.title
        alert.informativeText = problem.message
        for choice in problem.choices { alert.addButton(withTitle: choice.title) }
        let response = await present(alert, on: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard problem.choices.indices.contains(index) else { return problem.choices.contains(.keep) ? .keep : .copy }
        return problem.choices[index]
    }
}
