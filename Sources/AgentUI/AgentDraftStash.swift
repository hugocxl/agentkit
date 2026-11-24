import AgentCore
import AppKit
import CryptoKit

/// An unfinished alternative set aside from a conversation's composer, with what made it:
/// its text and quotations, attachments, review comments and settings.
struct AgentStashedDraft: Codable, Sendable, Identifiable, Equatable {
    struct Attachment: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var mimeType: String
        var byteCount: Int
        /// Absent for an attachment that couldn't be read when it was stashed.
        var sha256: String?
    }
    var id = UUID().uuidString
    var createdAt = Date()
    var text: String
    var spans: [AgentSavedDraft.Span]?
    var attachments: [Attachment]?
    var reviewComments: [AgentReviewComment]?
    var provider: AgentChatProvider?
    var model: String?
    var effort: AgentReasoningEffort?
    var planMode: Bool?
    /// Where it came from, such as a queued prompt's edit; nil for the composer.
    var origin: String?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (attachments ?? []).isEmpty && (reviewComments ?? []).isEmpty
    }

    /// One line for the stash list.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
        if !line.isEmpty { return line }
        if let first = attachments?.first { return first.name }
        return (reviewComments?.count ?? 0) == 1 ? "1 review comment" : "\(reviewComments?.count ?? 0) review comments"
    }
}

/// What a stashed draft holds now: its attachments that can still be read, and those that can't.
struct AgentStashRestore: Sendable {
    var entry: AgentStashedDraft
    var attachments: [AgentChatAttachment]
    var missing: [AgentStashedDraft.Attachment]
}

/// A conversation's stash, beside its draft: an index of entries and each entry's
/// attachment bytes in a folder of its own. Bytes are written before the index names
/// them, and the index forgets an entry before its folder goes, so a crash leaves at
/// worst an unlisted folder, never a listed entry whose bytes were never written.
actor AgentDraftStashStore {
    static let maximumEntries = 20
    static let maximumIndexBytes = 8 * 1024 * 1024
    let directory: URL
    private var index: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL) { self.directory = directory }

    /// The stash of the conversation whose draft is saved at `draftURL`.
    static func directory(forDraft draftURL: URL) -> URL {
        draftURL.deletingPathExtension().appendingPathExtension("stash")
    }

    func entries() throws -> [AgentStashedDraft] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        do {
            guard (try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maximumIndexBytes else {
                throw ModelError("The stash index exceeds its size limit.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AgentStashedDraft].self, from: Data(contentsOf: index))
        } catch {
            let recovery = index.appendingPathExtension("unreadable-" + UUID().uuidString)
            try FileManager.default.moveItem(at: index, to: recovery)
            throw ModelError("Could not read the stash. Its original bytes are preserved at \(recovery.path).")
        }
    }

    /// Adds `entry` with the bytes of `attachments`, which its attachment list names.
    func add(_ entry: AgentStashedDraft, attachments: [AgentChatAttachment]) throws {
        var list = try entries()
        guard list.count < Self.maximumEntries else {
            throw ModelError("The stash is full (\(Self.maximumEntries) drafts). Restore or discard one first.")
        }
        let folder = folder(entry.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for (offset, attachment) in attachments.enumerated() {
                let file = folder.appendingPathComponent("\(offset).bin")
                try attachment.data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            var stored = entry
            var described = attachments.map {
                AgentStashedDraft.Attachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, byteCount: $0.data.count, sha256: Self.digest($0.data))
            }
            // Attachments that couldn't be read when stashed stay listed, without bytes.
            described += (entry.attachments ?? []).filter { $0.sha256 == nil && !attachments.map(\.id).contains($0.id) }
            stored.attachments = described.isEmpty ? nil : described
            list.append(stored)
            try write(list)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The entry and the attachment bytes that are still whole; missing or altered bytes are listed.
    func load(_ id: String) throws -> AgentStashRestore {
        guard let entry = try entries().first(where: { $0.id == id }) else {
            throw ModelError("That stashed draft is no longer in the stash.")
        }
        var attachments: [AgentChatAttachment] = [], missing: [AgentStashedDraft.Attachment] = []
        for (offset, attachment) in (entry.attachments ?? []).enumerated() {
            let file = folder(id).appendingPathComponent("\(offset).bin")
            guard let digest = attachment.sha256,
                  (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == attachment.byteCount,
                  attachment.byteCount <= AgentChatAttachment.maxFileBytes,
                  let data = try? Data(contentsOf: file), Self.digest(data) == digest else {
                missing.append(attachment)
                continue
            }
            attachments.append(AgentChatAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, data: data))
        }
        return AgentStashRestore(entry: entry, attachments: attachments, missing: missing)
    }

    func remove(_ id: String) throws {
        let list = try entries()
        guard list.contains(where: { $0.id == id }) else { return }
        try write(list.filter { $0.id != id })
        try? FileManager.default.removeItem(at: folder(id))
    }

    private func write(_ list: [AgentStashedDraft]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(list)
        guard bytes.count <= Self.maximumIndexBytes else { throw ModelError("The stash is too large to save. Restore or discard a stashed draft first.") }
        try bytes.write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }

    /// Entry IDs are generated here, but the index is read from disk: only a UUID names a folder.
    private func folder(_ id: String) -> URL {
        directory.appendingPathComponent(UUID(uuidString: id)?.uuidString ?? Self.digest(Data(id.utf8)), isDirectory: true)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// How to bring back a stashed draft when the composer already holds one.
enum AgentStashRestoreChoice: Equatable {
    /// Adds it after the current draft.
    case merge
    /// Puts it in place of the current draft, which is stashed first.
    case replace
    case cancel
}

/// A question the restore of a stashed draft asks.
enum AgentStashQuestion: Equatable {
    /// The composer holds a draft: merge, replace, or cancel.
    case occupied(String)
    /// Some attachments can't be read any more: `merge` or `replace` restores the rest.
    case missingAttachments([String])
}

extension AgentPaneController {
    var stashStore: AgentDraftStashStore? { composerWork.stash }

    func configureStash(draftURL: URL) {
        composerWork.stash = AgentDraftStashStore(directory: AgentDraftStashStore.directory(forDraft: draftURL))
    }

    /// Takes a leading `/command` and the space after it out of the composer, keeping the
    /// rest of the draft and its quotations as they are.
    func removeLeadingCommand() {
        guard let storage = surface.composer.textStorage else { return }
        let text = storage.string as NSString
        let start = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard start.location != NSNotFound, text.substring(with: start) == "/" else { return }
        var end = start.location
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        storage.deleteCharacters(in: NSRange(location: 0, length: end))
        surface.refreshComposer()
        saveDraft()
    }

    private var draftIsOccupied: Bool {
        !surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty || !reviewComments.isEmpty
    }

    private func stashEntry(from draft: AgentSavedDraft) -> AgentStashedDraft {
        AgentStashedDraft(text: draft.text, spans: draft.spans.isEmpty ? nil : draft.spans,
                          attachments: draft.attachments.map { .init(id: $0.id, name: $0.name, mimeType: $0.mimeType, byteCount: $0.data.count, sha256: nil) },
                          reviewComments: draft.reviewComments, provider: selection.provider, model: selection.model,
                          effort: reasoningEffort, planMode: snapshot?.planMode)
    }

    /// Sets the draft aside in the conversation's stash and clears what was stashed from
    /// the composer. Anything typed while the stash was being written stays.
    func stashDraft() {
        guard !disposed, !restoringDraft, composerWork.stashTask == nil else { return }
        guard let store = stashStore else { showComposerError("Stashing drafts is unavailable in this conversation."); return }
        let draft = captureDraft()
        let entry = stashEntry(from: draft)
        guard !entry.isEmpty else { showNotice("There is no draft to stash.", kind: .info); return }
        let sentText = surface.composer.attributedString().copy() as? NSAttributedString
        let stashedAttachments = Set(draft.attachments.map(\.id)), stashedComments = Set((draft.reviewComments ?? []).map(\.id))
        composerWork.stashTask = Task { [weak self] in
            do {
                try await store.add(entry, attachments: draft.attachments)
            } catch {
                self?.composerWork.stashTask = nil
                self?.showComposerError("Couldn't stash the draft: \(error.localizedDescription) Your draft is unchanged.")
                return
            }
            guard let self else { return }
            self.composerWork.stashTask = nil
            guard !self.disposed else { return }
            // The draft that was stashed is cleared; its pending imports go with it.
            self.invalidateImports()
            if let sentText, self.surface.composer.attributedString().isEqual(to: sentText) { self.surface.composer.string = "" }
            self.draftAttachments.removeAll { stashedAttachments.contains($0.id) }
            self.reviewComments.removeAll { stashedComments.contains($0.id) }
            self.refreshReviewComments()
            self.lastSubmission = nil
            self.updateAttachments()
            self.surface.refreshComposer()
            self.saveDraft(immediate: true)
            self.showNotice("Stashed the draft. Use /stashes to bring it back.", kind: .info)
        }
    }

    /// Stashes a queued prompt's edit the server didn't take, fetching the attachments it
    /// kept from the prompt; one that can't be fetched is listed as unavailable.
    func stashQueueEdit(_ edit: AgentQueuedPromptEdit) {
        guard let store = stashStore else { showComposerError("Stashing drafts is unavailable in this conversation."); return }
        let fetch = surface.fetchAttachment
        let provider = selection.provider
        Task { [weak self] in
            var attachments: [AgentChatAttachment] = [], unavailable: [AgentStashedDraft.Attachment] = []
            for attachment in edit.attachments {
                switch attachment {
                case .added(let added): attachments.append(added)
                case .existing(let descriptor):
                    if let fetch, let data = try? await fetch(edit.promptID, descriptor) {
                        attachments.append(AgentChatAttachment(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, data: data))
                    } else {
                        unavailable.append(.init(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, byteCount: descriptor.byteCount, sha256: nil))
                    }
                }
            }
            let entry = AgentStashedDraft(text: edit.text, attachments: unavailable.isEmpty ? nil : unavailable, provider: provider,
                                          model: edit.settings?.model, effort: edit.settings?.effort, planMode: edit.settings?.planMode,
                                          origin: "queued prompt edit")
            do {
                try await store.add(entry, attachments: attachments)
                self?.showNotice("Stashed your edit. Use /stashes to bring it back." + (unavailable.isEmpty ? "" : " Some of its attachments couldn't be read."), kind: .info)
            } catch {
                self?.showComposerError("Couldn't stash your edit: \(error.localizedDescription)")
            }
        }
    }

    /// Lists the stash to choose a draft to bring back.
    func showStashes() {
        guard !disposed, let store = stashStore else { showComposerError("Stashing drafts is unavailable in this conversation."); return }
        Task { [weak self] in
            do {
                let entries = try await store.entries()
                guard let self, !self.disposed else { return }
                let picker = AgentSearchPicker(title: "Stashed drafts", placeholder: "Search stashed drafts…", theme: self.surface.theme)
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                picker.update(entries.reversed().map { entry in
                    let files = entry.attachments?.count ?? 0
                    return .init(id: entry.id, title: entry.title, detail: formatter.localizedString(for: entry.createdAt, relativeTo: Date())
                        + (files == 0 ? "" : files == 1 ? " · 1 attachment" : " · \(files) attachments")
                        + (entry.model.map { " · " + $0 } ?? "") + (entry.origin.map { " · from a " + $0 } ?? ""))
                }, note: entries.isEmpty ? "Nothing is stashed. Use /stash to set a draft aside." : "Return restores a draft; nothing is sent.")
                picker.onSelect = { [weak self] id in self?.restoreStash(id) }
                picker.present(in: self.surface.window)
            } catch { self?.showComposerError(error.localizedDescription) }
        }
    }

    /// Brings a stashed draft back into the composer. An empty composer takes it; an
    /// occupied one asks to merge or replace, and replacing stashes the current draft
    /// first. It leaves the stash only once the composer's draft holding it is saved.
    /// Restoring never sends anything.
    func restoreStash(_ id: String) {
        guard !disposed, composerWork.stashTask == nil else { return }
        guard let store = stashStore else { showComposerError("Stashing drafts is unavailable in this conversation."); return }
        composerWork.stashTask = Task { [weak self] in
            guard let self else { return }
            defer { self.composerWork.stashTask = nil }
            do {
                let restore = try await store.load(id)
                guard !self.disposed else { return }
                let ask = self.composerWork.askStash ?? self.presentStashQuestion
                if !restore.missing.isEmpty {
                    guard await ask(.missingAttachments(restore.missing.map(\.name))) != .cancel, !self.disposed else { return }
                }
                var choice = AgentStashRestoreChoice.replace
                if self.draftIsOccupied {
                    choice = await ask(.occupied(restore.entry.title))
                    guard choice != .cancel, !self.disposed else { return }
                }
                if choice == .merge {
                    try self.merge(restore)
                } else {
                    if self.draftIsOccupied {
                        let current = self.captureDraft()
                        try await store.add(self.stashEntry(from: current), attachments: current.attachments)
                    }
                    await self.replaceDraft(with: restore)
                }
                guard !self.disposed else { return }
                try await self.flushDraft()
                try await store.remove(id)
                let missing = restore.missing.map { "“\($0.name)”" }.joined(separator: ", ")
                self.showNotice((choice == .merge ? "Added the stashed draft to yours." : "Restored the stashed draft.")
                    + (missing.isEmpty ? "" : " Unavailable and not restored: \(missing).")
                    + (restore.entry.planMode == true && self.snapshot?.planMode != true ? " It was written in plan mode." : ""),
                    kind: missing.isEmpty ? .info : .warning)
            } catch {
                guard !self.disposed else { return }
                self.showComposerError("Couldn't restore the stashed draft: \(error.localizedDescription) It stays in the stash.")
            }
        }
    }

    private func merge(_ restore: AgentStashRestore) throws {
        let entry = restore.entry
        let editor = surface.composer
        let separator = editor.string.isEmpty || entry.text.isEmpty ? "" : "\n\n"
        let additions = restore.attachments.filter { candidate in !draftAttachments.contains { $0.id == candidate.id || ($0.name == candidate.name && $0.data == candidate.data) } }
        guard editor.string.utf8.count + separator.utf8.count + entry.text.utf8.count <= 256 * 1024 else {
            throw ModelError("Together the drafts would exceed the draft size limit. Choose Replace instead.")
        }
        guard draftAttachments.count + additions.count <= AgentChatAttachment.maxCount,
              (draftAttachments.map(\.data) + additions.map(\.data)).reduce(0, { $0 + $1.count }) <= AgentChatAttachment.maxTotalBytes else {
            throw ModelError("Together the drafts would have more attachments than a message can carry. Choose Replace instead.")
        }
        let text = AgentSavedDraft.attributed(text: entry.text, spans: entry.spans ?? [], theme: surface.theme)
        editor.textStorage?.append(NSAttributedString(string: separator, attributes: [.font: AppFont.system(14, weight: .light), .foregroundColor: surface.theme.fg]))
        editor.textStorage?.append(text)
        draftAttachments += additions.map { AgentDraftAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        let known = Set(reviewComments.map(\.id))
        reviewComments += (entry.reviewComments ?? []).filter { !known.contains($0.id) }
        refreshReviewComments()
        lastSubmission = nil
        updateAttachments()
        surface.refreshComposer()
        loadThumbnails(for: additions.map(\.id))
    }

    private func replaceDraft(with restore: AgentStashRestore) async {
        let entry = restore.entry
        invalidateImports()
        surface.composer.textStorage?.setAttributedString(AgentSavedDraft.attributed(text: entry.text, spans: entry.spans ?? [], theme: surface.theme))
        draftAttachments = restore.attachments.map { AgentDraftAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        reviewComments = entry.reviewComments ?? []
        refreshReviewComments()
        lastSubmission = nil
        if let provider = entry.provider, provider == selection.provider || !switchingHandsOff, canEditSelection,
           entry.model != selection.model || provider != selection.provider {
            selectModel(provider: provider, model: entry.model)
        }
        if entry.effort != reasoningEffort, entry.effort.map({ supportedEfforts.contains($0) }) ?? true { selectEffort(entry.effort) }
        updateAttachments()
        surface.refreshComposer()
        loadThumbnails(for: draftAttachments.map(\.id))
    }

    /// Gives restored images their thumbnails, off the main thread.
    private func loadThumbnails(for ids: [String]) {
        let images = draftAttachments.filter { ids.contains($0.id) && $0.mimeType.hasPrefix("image/") && $0.thumbnail == nil }
        guard !images.isEmpty else { return }
        Task { [weak self] in
            for image in images {
                guard let thumbnail = await AgentAttachmentImporter.previewImage(data: image.data, pixels: 160),
                      let self, let index = self.draftAttachments.firstIndex(where: { $0.id == image.id }) else { continue }
                self.draftAttachments[index] = AgentDraftAttachment(id: image.id, name: image.name, mimeType: image.mimeType, data: image.data, thumbnail: thumbnail)
                self.surface.attachmentStrip.update(self.draftAttachments, theme: self.surface.theme)
            }
        }
    }

    private func presentStashQuestion(_ question: AgentStashQuestion) async -> AgentStashRestoreChoice {
        guard let window = surface.window else { return .cancel }
        let alert = NSAlert()
        switch question {
        case .occupied(let title):
            alert.messageText = "Restore “\(title)”?"
            alert.informativeText = "The composer already holds a draft. Merge adds the stashed draft after it. Replace puts it in place of your draft, which is stashed first."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            switch await present(alert, on: window) {
            case .alertFirstButtonReturn: return .merge
            case .alertSecondButtonReturn: return .replace
            default: return .cancel
            }
        case .missingAttachments(let names):
            alert.messageText = names.count == 1 ? "An attachment is unavailable" : "\(names.count) attachments are unavailable"
            alert.informativeText = names.joined(separator: "\n") + "\n\nRestore the rest of the draft without them? Nothing is sent."
            alert.addButton(withTitle: "Restore Without Them")
            alert.addButton(withTitle: "Cancel")
            return await present(alert, on: window) == .alertFirstButtonReturn ? .replace : .cancel
        }
    }
}
