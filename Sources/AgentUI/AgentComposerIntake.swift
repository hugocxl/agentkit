import AgentCore
import AppKit

/// Composer work that outlives a single call: imports bound to the draft they started in,
/// a queued prompt's edit until the server takes it, and the conversation's stash.
@MainActor
final class AgentComposerWork {
    /// Changes whenever the draft is cleared, replaced or disposed. An import finishing
    /// under an older generation belongs to a draft that no longer exists.
    var draftGeneration: UInt64 = 0
    /// Imports still preparing, each with the task doing it.
    var imports: [UUID: Task<Void, Never>] = [:]
    /// The newest import; the next one waits for it, so attachments keep their order.
    var lastImport: Task<Void, Never>?
    /// What the composer says while imports prepare, such as an image being optimized.
    var preparation: String?
    /// A queued prompt's edit the server has not confirmed yet.
    var queueEdit: AgentQueuedPromptEdit?
    var queueEditTask: Task<Void, Never>?
    var stash: AgentDraftStashStore?
    var stashTask: Task<Void, Never>?
    var sendNowTask: Task<Void, Never>?
    /// A prompt sent with Send Now whose outcome is not known yet.
    var sendNow: AgentSendNowAttempt?
    /// Asks how to bring back a stashed draft; nil asks with a sheet.
    var askStash: ((AgentStashQuestion) async -> AgentStashRestoreChoice)?
    /// What Send Now came to, most recent last, for tests and diagnostics.
    private(set) var sendNowOutcomes: [AgentSendNowOutcome] = []
    func record(_ outcome: AgentSendNowOutcome) { sendNowOutcomes.append(outcome) }
    /// Shows a queued prompt's editor and returns the edit to save, nil when cancelled;
    /// nil shows the native sheet.
    var presentQueueEdit: ((AgentQueuedPromptEdit, String) async -> AgentQueuedPromptEdit?)?
    /// Asks what becomes of a queued prompt's edit the server didn't take; nil asks with a sheet.
    var resolveQueueEdit: ((AgentQueueEditProblem) async -> AgentQueueEditProblem.Choice)?
    /// Asks whether to attach optimized copies of the named images; nil asks with a sheet.
    var offerImageOptimization: ((_ names: [String], _ detail: String) async -> Bool)?
}

/// What became of a long paste.
enum AgentLongPasteOutcome: Equatable {
    /// It is in the draft as a text attachment.
    case attached
    /// It goes into the message text; the string says why, when it was meant to be attached.
    case inline(String?)
    /// Nothing was added, for the reason given.
    case rejected(String)
}

/// Whether attachments can join the draft.
enum AgentAttachmentAdmission: Equatable {
    case admitted
    /// Each one is already in the draft.
    case alreadyAttached
    case tooMany
    case tooLarge
    case unsupported
}

extension AgentPaneController {
    /// The longest message text a prompt can carry.
    static let messageTextBytes = 64 * 1024

    var preparingAttachments: Int { composerWork.imports.count }

    /// Whether `text` pasted over the current selection keeps the message within its limit.
    func inlinePasteFits(_ text: String) -> Bool {
        let composer = surface.composer
        let current = composer.string as NSString
        let selection = composer.selectedRange()
        let replaced = NSMaxRange(selection) <= current.length ? current.substring(with: selection).utf8.count : 0
        return composer.string.utf8.count - replaced + text.utf8.count <= Self.messageTextBytes
    }

    /// A long paste goes in as a text file so the draft stays readable. It reports what
    /// actually happened: attached, inline when it can't be attached but fits the message,
    /// or nothing, with the reason shown.
    func attachLongPaste(_ text: String) -> AgentLongPasteOutcome {
        guard !disposed else { return .rejected("The conversation is closed.") }
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard text.count >= Self.longPasteCharacters || lines >= Self.longPasteLines else { return .inline(nil) }
        let limitKB = Self.messageTextBytes / 1024
        guard capabilities.contains(.attachments) else {
            guard inlinePasteFits(text) else {
                let reason = "The paste is longer than the \(limitKB) KB message limit, and this conversation can't take attachments."
                showComposerError(reason)
                return .rejected(reason)
            }
            return .inline(nil)
        }
        let attachment = AgentDraftAttachment(name: "Pasted text (\(lines) lines).txt", mimeType: "text/plain", data: Data(text.utf8))
        let admission = admit([attachment])
        switch admission {
        case .admitted:
            draftAttachments.append(attachment)
            updateAttachments()
            guard draftAttachments.contains(where: { $0.id == attachment.id }) else { return .rejected("The paste could not be attached.") }
            showNotice("The long paste was attached as a text file.", kind: .info)
            return .attached
        case .alreadyAttached:
            showNotice("This text is already attached.", kind: .info)
            return .attached
        case .tooMany, .tooLarge, .unsupported:
            let reason = admissionReason(admission, bytes: attachment.data.count)
            guard inlinePasteFits(text) else {
                let message = "The paste wasn't added. \(reason) It is also longer than the \(limitKB) KB message limit."
                showComposerError(message)
                return .rejected(message)
            }
            showNotice("\(reason) The paste was inserted as text instead.", kind: .info)
            return .inline(reason)
        }
    }

    /// Whether `attachments` can join the draft as it is, within the count and byte limits.
    func admit(_ attachments: [AgentDraftAttachment]) -> AgentAttachmentAdmission {
        guard capabilities.contains(.attachments) else { return .unsupported }
        let additions = attachments.filter { candidate in
            !draftAttachments.contains { $0.name == candidate.name && $0.data == candidate.data }
        }
        if additions.isEmpty, !attachments.isEmpty { return .alreadyAttached }
        guard draftAttachments.count + additions.count <= AgentChatAttachment.maxCount else { return .tooMany }
        guard additions.allSatisfy({ $0.data.count <= AgentChatAttachment.maxFileBytes }),
              (draftAttachments + additions).reduce(0, { $0 + $1.data.count }) <= AgentChatAttachment.maxTotalBytes else { return .tooLarge }
        return .admitted
    }

    func admissionReason(_ admission: AgentAttachmentAdmission, bytes: Int) -> String {
        let limitMB = AgentChatAttachment.maxTotalBytes / 1024 / 1024
        switch admission {
        case .tooMany: return "The draft already has \(AgentChatAttachment.maxCount) attachments."
        case .tooLarge:
            return bytes > AgentChatAttachment.maxFileBytes ? "It is over the \(limitMB) MB attachment limit."
                : "It would bring the draft's attachments over \(limitMB) MB."
        case .unsupported: return Self.attachmentsUnavailable
        case .admitted, .alreadyAttached: return ""
        }
    }

    /// Adds attachments to the draft, or says why they can't join it.
    func addAttachments(_ attachments: [AgentDraftAttachment]) {
        let admission = admit(attachments)
        switch admission {
        case .admitted:
            draftAttachments += attachments.filter { candidate in
                !draftAttachments.contains { $0.name == candidate.name && $0.data == candidate.data }
            }
            dismissNotice()
            updateAttachments()
        case .alreadyAttached: showNotice(attachments.count == 1 ? "That file is already attached." : "Those files are already attached.", kind: .info)
        case .unsupported: showComposerError(Self.attachmentsUnavailable)
        case .tooMany, .tooLarge:
            showComposerError("Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB.")
        }
    }

    /// Prepares attachments for the draft as it is now. If the draft is cleared, replaced
    /// or disposed before this finishes, the result is dropped rather than added to the
    /// next draft. Images too large to send are offered as optimized copies.
    func prepareAttachments(_ label: String? = nil, _ load: @escaping @Sendable () async throws -> AgentAttachmentIntake) {
        let work = composerWork
        let generation = work.draftGeneration
        let previous = work.lastImport
        let token = UUID()
        if let label { work.preparation = label }
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.finishImport(token) }
            do {
                try Task.checkCancellation()
                guard !self.disposed, generation == work.draftGeneration else { return }
                var intake = try await load()
                try Task.checkCancellation()
                guard !self.disposed, generation == work.draftGeneration else { return }
                // Images that fit alone but not beside the draft's other attachments can be optimized too.
                if self.admit(intake.attachments) == .tooLarge {
                    let images = intake.attachments.filter { $0.mimeType.hasPrefix("image/") }
                    let others = intake.attachments.filter { !$0.mimeType.hasPrefix("image/") }
                    if !images.isEmpty, self.admit(others) == .admitted || others.isEmpty {
                        intake.attachments = others
                        intake.oversizedImages += images.map { .init(name: $0.name, source: .data($0.data), byteCount: $0.data.count) }
                    }
                }
                if !intake.attachments.isEmpty { self.addAttachments(intake.attachments) }
                if !intake.oversizedImages.isEmpty { self.offerOptimization(intake.oversizedImages, generation: generation) }
            } catch is CancellationError {
            } catch {
                guard !self.disposed, generation == work.draftGeneration else { return }
                self.showComposerError(error.localizedDescription)
            }
        }
        work.imports[token] = task
        work.lastImport = task
        updateControls()
    }

    private func finishImport(_ token: UUID) {
        guard composerWork.imports.removeValue(forKey: token) != nil else { return }
        if composerWork.imports.isEmpty { composerWork.lastImport = nil; composerWork.preparation = nil }
        updateControls()
    }

    /// Ends every import of the current draft, queued or running: the draft is being
    /// cleared, replaced or disposed, so none of them may add to what comes next.
    func invalidateImports() {
        composerWork.draftGeneration &+= 1
        let running = composerWork.imports.values
        composerWork.imports.removeAll()
        composerWork.lastImport = nil
        composerWork.preparation = nil
        for task in running { task.cancel() }
        updateControls()
    }

    /// Stops preparing attachments, at the user's request; the draft keeps what it has.
    func cancelAttachmentPreparation() {
        guard preparingAttachments > 0 else { return }
        invalidateImports()
        showNotice("Stopped preparing attachments. Your draft is unchanged.", kind: .info)
    }

    /// Asks whether to attach optimized copies, then makes them within the draft's budget.
    private func offerOptimization(_ images: [AgentOversizedImage], generation: UInt64) {
        let names = images.map { "“\($0.name)”" }.joined(separator: ", ")
        let size = ByteCountFormatter.string(fromByteCount: Int64(images.reduce(0) { $0 + $1.byteCount }), countStyle: .file)
        let limit = AgentChatAttachment.maxTotalBytes / 1024 / 1024
        let detail = "\(names) (\(size)) won't fit the \(limit) MB attachment limit. An optimized copy is smaller and lower in resolution; the original stays unchanged."
        let work = composerWork
        Task { [weak self] in
            guard let self else { return }
            let accepted = await (work.offerImageOptimization ?? self.presentOptimizationOffer)(images.map(\.name), detail)
            guard accepted, !self.disposed, generation == work.draftGeneration else { return }
            let label = images.count == 1 ? "Optimizing \(names) to fit the attachment limit…" : "Optimizing \(images.count) images to fit the attachment limit…"
            for image in images {
                let used = self.draftAttachments.reduce(0) { $0 + $1.data.count }
                let budget = min(AgentChatAttachment.maxFileBytes, (AgentChatAttachment.maxTotalBytes - used) / max(1, images.count))
                self.prepareAttachments(label) {
                    AgentAttachmentIntake(attachments: [try await AgentImageOptimizer.optimize(image, budget: budget)])
                }
            }
        }
    }

    private func presentOptimizationOffer(_ names: [String], _ detail: String) async -> Bool {
        guard let window = surface.window else { return false }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Attach an optimized copy?" : "Attach optimized copies?"
        alert.informativeText = detail
        alert.addButton(withTitle: names.count == 1 ? "Attach Optimized Copy" : "Attach Optimized Copies")
        alert.addButton(withTitle: "Cancel")
        return await present(alert, on: window) == .alertFirstButtonReturn
    }
}
