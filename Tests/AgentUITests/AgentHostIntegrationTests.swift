import AgentCore
import AppKit
import XCTest
@testable import AgentUI

/// The host boundaries an embedding application relies on: notices appear where the
/// host shows its own, repository identity is read once per connection, and marks
/// follow the conversation's theme rather than the shared one.
@MainActor
final class AgentHostIntegrationTests: XCTestCase {
    private final class DiagramTextDelegate: NSObject, NSTextViewDelegate {}

    private final class Calls {
        var origins = 0
        var failure: Error?
        var notices: [(String, Toast.Style)] = []
    }

    /// Holds work at a point until let go.
    private final class Gate: @unchecked Sendable {
        var entered = false
        var open = false
    }

    private final class Requests: @unchecked Sendable {
        var values: [AgentConversationRequest] = []
    }

    private static let checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "a.swift", additions: 1, deletions: 1)],
                                                        totalFiles: 1, additions: 1, deletions: 1)

    private func settle(_ condition: () -> Bool = { true }) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
    }

    func testRepositoryIdentityIsReadOncePerConnectionUnlessTheConnectionFailed() async throws {
        let calls = Calls()
        calls.failure = ErrorReply(code: .badRequest, message: "Git worktree is missing")
        var services = AgentHostServices(directory: { "/tmp" }, isLocal: { true })
        services.repositoryOrigin = {
            calls.origins += 1
            if let failure = calls.failure { throw failure }
            return "git@github.com:example/project.git"
        }
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let host = AgentHostActions(surface: surface, session: SessionId(), services: services)

        host.refreshProjectMetadata()
        try await settle { calls.origins == 1 }
        for _ in 0..<5 { host.refreshProjectMetadata(); try await settle() }
        XCTAssertEqual(calls.origins, 1, "A folder outside Git answers once per connection")

        host.connectionChanged()
        calls.failure = URLError(.networkConnectionLost)
        host.refreshProjectMetadata()
        try await settle { calls.origins == 2 }
        host.refreshProjectMetadata()
        try await settle { calls.origins == 3 }
        XCTAssertEqual(calls.origins, 3, "A failure without an error code, such as a dropped connection, retries")

        calls.failure = nil
        host.refreshProjectMetadata()
        try await settle { calls.origins == 4 }
        for _ in 0..<3 { host.refreshProjectMetadata(); try await settle() }
        XCTAssertEqual(calls.origins, 4, "A found identity holds until the connection changes")
        XCTAssertTrue(surface.linkServices.pullRequestHosts.contains("github.com"))
    }

    func testImageNoticesAppearWhereTheHostShowsItsOwn() async throws {
        _ = NSApplication.shared
        let calls = Calls()
        var services = AgentHostServices()
        services.showNotice = { calls.notices.append(($0, $1)) }
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.actions.project = AgentHostActions(surface: surface, session: SessionId(), services: services)
        let image = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        surface.addSubview(image)
        let actions = AgentImageActions(name: "photo.png")
        actions.view = image
        actions.fetch = { throw URLError(.cannotDecodeContentData) }

        actions.copyImage()
        try await settle { calls.notices.count == 2 }
        XCTAssertEqual(calls.notices.map(\.0).first, "Copying image…")
        XCTAssertEqual(calls.notices.count, 2)
        XCTAssertTrue(calls.notices.last?.0.hasPrefix("Could not copy image") == true)
        XCTAssertEqual(calls.notices.last.map { "\($0.1)" }, "error")
    }

    func testWithoutAHostNoticesUseTheWindowsNoticeStack() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        let stack = NoticeStack(frame: content.bounds)
        content.addSubview(stack)
        let surface = AgentPaneView(frame: content.bounds)
        surface.actions.project = AgentHostActions(surface: surface, session: SessionId(), services: AgentHostServices())
        content.addSubview(surface)
        window.contentView = content

        Toast.show("Link copied", in: surface)
        let shown = stack.subviews.compactMap { ($0 as? NoticeView)?.notice?.message }
        XCTAssertEqual(shown, ["Link copied"])
    }

    func testProviderLogosLinkMarksAndIconButtonsFollowTheirTheme() throws {
        _ = NSApplication.shared
        let paper = ColorScheme(background: RGBColor(0xFAFAF7), foreground: RGBColor(0x202020))
        let night = ColorScheme(background: RGBColor(0x101014), foreground: RGBColor(0xE8E8EC))
        let catalog = ThemeCatalog(entries: [ThemeEntry(name: "Paper", scheme: paper), ThemeEntry(name: "Night", scheme: night)])
        let light = AgentTheme(catalog: catalog, darkTheme: "Night", lightTheme: "Paper", systemIsDark: false)
        let dark = AgentTheme(catalog: catalog, darkTheme: "Night", lightTheme: "Paper", systemIsDark: true)
        XCTAssertTrue(light.palette.isLight)
        XCTAssertFalse(dark.palette.isLight)
        func pixels(_ image: NSImage?) throws -> Data { try XCTUnwrap(XCTUnwrap(image).tiffRepresentation) }

        XCTAssertNotEqual(try pixels(AgentLogo.image(for: .claude, theme: light)), try pixels(AgentLogo.image(for: .claude, theme: dark)))
        XCTAssertEqual(try pixels(AgentLogo.image(for: .claude, theme: dark)), try pixels(AppIcon.claude.image(size: 64, theme: dark)))

        let github = try XCTUnwrap(URL(string: "https://github.com/example/project/pull/1"))
        let favicons = AgentLinkFavicon(fetch: { _ in throw URLError(.badURL) })
        XCTAssertNotEqual(try pixels(favicons.image(for: github, color: .blue, theme: light)),
                          try pixels(favicons.image(for: github, color: .blue, theme: dark)))

        let button = IconButton(.close, label: "Close")
        button.theme = light
        let lightTint = try pixels(button.image)
        button.theme = dark
        XCTAssertNotEqual(try pixels(button.image), lightTint, "The glyph is tinted in the button's own theme")
    }

    func testABackendTooOldForAServiceIsDescribedInTheHostsWords() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2)
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        pane.backendAdvice = AgentBackendAdvice(restart: "Update Tab on it, then restart it.")
        pane.conversationRequest = { _ in throw ErrorReply(code: .unsupported, message: "") }
        let checkpoint = AgentTurnCheckpoint(id: UUID().uuidString, files: [.init(path: "a.swift", additions: 1, deletions: 0)],
                                             totalFiles: 1, additions: 1, deletions: 0)
        pane.confirmDestructive = { _, _, _ in true }
        pane.revertTurn(checkpoint, paths: nil)
        try await settle { pane.notice != nil }
        XCTAssertEqual(pane.notice?.text, "This server can't revert a turn's changes. Update Tab on it, then restart it.")

        var connection = AgentConnection(project: project, provider: .claude, request: { _ in snapshot }, observe: { AsyncStream { $0.finish() } })
        connection.backendAdvice = AgentBackendAdvice(restart: "Restart the companion app.", clear: "Update the companion app to clear in place.")
        let conversation = AgentConversationViewController(connection: connection)
        defer { conversation.dispose() }
        XCTAssertEqual(conversation.controller.backendAdvice, connection.backendAdvice)
        XCTAssertEqual(AgentBackendAdvice().cannot("show earlier messages"),
                       "This server can't show earlier messages. Update or restart the conversation backend.")
    }

    /// A conversation chosen from history opens beside one in use only where the host can
    /// show another conversation; elsewhere nothing is imported, and the pane says why. An
    /// unused pane takes it over, and a failure says what went wrong in the runtime's words.
    func testHistoryIsImportedOnlyWhereItCanBeShown() async throws {
        _ = NSApplication.shared
        let project = ProjectId()
        let entry = AgentHistoryEntry(provider: .claude, providerSession: "past", title: "Past work", updatedAt: Date())
        var targets: [SessionId] = []
        func pane(items: [AgentChatItem]) -> AgentPaneController {
            let session = SessionId()
            let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2, items: items)
            let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
            pane.loadHistory = { AgentHistoryReply(entries: [entry]) }
            pane.importHistory = { _, target in
                targets.append(target)
                throw ServiceError(.badRequest, "This conversation is too large to open")
            }
            return pane
        }
        func choose(_ entry: AgentHistoryEntry, in pane: AgentPaneController) async throws {
            pane.refresh()
            try await settle { pane.snapshot != nil }
            XCTAssertNotNil(pane.snapshot)
            pane.showHistory()
            try await settle { pane.historyPicker != nil }
            pane.historyPicker?.onSelect?(entry.id)
            pane.historyPicker?.close()
        }
        let used = pane(items: [AgentChatItem(kind: .user, text: "Hello")])
        defer { used.dispose() }
        try await choose(entry, in: used)
        try await settle()
        XCTAssertEqual(targets, [], "Nothing is imported where nothing would show it")
        XCTAssertEqual(used.notice?.text, "Opening another conversation is unavailable. Continue it from a new conversation.")

        let unused = pane(items: [])
        defer { unused.dispose() }
        try await choose(entry, in: unused)
        try await settle { unused.notice != nil }
        XCTAssertEqual(targets, [unused.session])
        XCTAssertEqual(unused.notice?.text, "Couldn't continue that conversation: This conversation is too large to open")
    }

    /// A conversation whose backend takes no attachments refuses a pasted image, and a
    /// draft kept with attachments is refused at send, kept as written.
    func testAttachmentsAreRefusedWhereTheBackendTakesNone() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { conversation.dispose(); window.close() }
        let pane = conversation.controller
        pane.refresh()
        try await settle { pane.snapshot != nil }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        pane.surface.composer.onAttachImage?(png, "image/png")
        try await settle { pane.draftAttachments.count == 1 }
        XCTAssertEqual(pane.draftAttachments.count, 1, "Taken while the backend takes attachments")

        pane.capabilities = []
        pane.surface.composer.onAttachImage?(png, "image/png")
        try await settle()
        XCTAssertEqual(pane.draftAttachments.count, 1, "A paste is refused")
        XCTAssertEqual(pane.notice?.text, "This conversation can't take attachments.")
        pane.send()
        XCTAssertEqual(pane.notice?.text, "This conversation can't take attachments. Remove them to send.")
        XCTAssertEqual(pane.draftAttachments.count, 1, "The draft stays as written")
    }

    /// A failed turn whose message had attachments isn't sent again where the backend takes
    /// none: Retry says why instead.
    func testRetryKeepsAttachmentsFromABackendThatTakesNone() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let descriptor = AgentChatAttachmentDescriptor(id: "notes", name: "notes.txt", mimeType: "text/plain", byteCount: 5)
        let user = AgentChatItem(id: "u1", kind: .user, text: "Read this", attachments: [descriptor])
        let turn = AgentChatTurn(userItemID: "u1", startedAt: Date(), completedAt: Date(), outcome: .failed)
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, turns: [turn],
                                         status: .failed, revision: 2, items: [user])
        var submitted = 0
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { request in
            if case .submit = request { submitted += 1 }
            return snapshot
        }
        defer { pane.dispose() }
        pane.surface.fetchAttachment = { _, _ in Data("Notes".utf8) }
        pane.refresh()
        try await settle { pane.snapshot != nil }
        XCTAssertNotNil(pane.retryableTurnItem)
        pane.capabilities = []
        pane.retryLastTurn()
        try await settle()
        XCTAssertEqual(submitted, 0, "Not sent again")
        XCTAssertEqual(pane.notice?.text, "This conversation can't take attachments. Its attachments can't be sent again.")
    }

    /// Where the host can't show another conversation, a history import answered with the
    /// one already continuing it says so instead of doing nothing.
    func testAnImportAnsweredWithAnotherConversationSaysSoWithoutNavigation() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 2)
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { _ in snapshot }
        defer { pane.dispose() }
        let entry = AgentHistoryEntry(provider: .claude, providerSession: "past", title: "Past work", updatedAt: Date())
        pane.loadHistory = { AgentHistoryReply(entries: [entry]) }
        pane.importHistory = { _, _ in
            AgentChatSnapshot(session: SessionId(), project: project, provider: .claude, providerSession: "past")
        }
        pane.refresh()
        try await settle { pane.snapshot != nil }
        pane.showHistory()
        try await settle { pane.historyPicker != nil }
        pane.historyPicker?.onSelect?(entry.id)
        pane.historyPicker?.close()
        try await settle { pane.notice != nil }
        XCTAssertEqual(pane.notice?.text, "That conversation is already continued in another one.")
    }

    /// A draft attachment's open preview follows its conversation into a replaced theme.
    func testAnAttachmentPreviewFollowsItsConversationIntoANewTheme() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { conversation.dispose(); window.close() }
        window.orderFront(nil)
        let pane = conversation.controller
        pane.refresh()
        try await settle { pane.snapshot != nil }
        let notes = Data("Notes".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).txt")
        try notes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pane.attachFiles([file])
        try await settle { pane.draftAttachments.count == 1 }
        let id = try XCTUnwrap(pane.draftAttachments.first?.id)
        pane.surface.attachmentStrip.onPreview?(id)
        let shown = try XCTUnwrap(pane.attachmentPreview)
        XCTAssertTrue(shown.isShown)
        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        let preview = try XCTUnwrap(pane.attachmentPreview)
        XCTAssertTrue((preview.contentViewController?.view as? ThemedBackground)?.theme === replaced)
        preview.close()
    }

    /// A transcript shown again in another theme of the same colors draws its icons in that
    /// theme, not in the one it replaced, which may since have changed: footnotes too.
    func testATranscriptKeepsNoThemeItWasReplacedWith() throws {
        _ = NSApplication.shared
        let first = Self.paper(), second = Self.paper()
        XCTAssertEqual(first.palette, second.palette)
        let response = AgentResponseView(frame: .zero)
        let source = "See [the change](https://github.com/example/project/pull/1)[^1].\n\n[^1]: [GitHub](https://github.com/example)"
        response.setContent(source, theme: first)
        _ = response.height(for: 420)
        // The themes of the text showing links: the prose's and the footnote's.
        func linkThemes() -> [AgentTheme] {
            response.sectionViews.flatMap { section -> [AgentRichTextView] in
                if let prose = section as? AgentResponseProse { return [prose.text] }
                return (section as? AgentResponseFootnotes)?.textViews ?? []
            }.filter { text in
                guard let storage = text.textStorage else { return false }
                var linked = false
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                    if value != nil { linked = true; stop.pointee = true }
                }
                return linked
            }.map(\.linkIconTheme)
        }
        XCTAssertEqual(linkThemes().count, 2, "The prose and its footnote")
        XCTAssertTrue(linkThemes().allSatisfy { $0 === first })
        response.setContent(source, theme: second)
        XCTAssertTrue(linkThemes().allSatisfy { $0 === second }, "Footnotes take the replacing theme too")
    }

    /// An expanded image covers the conversation, so its copy and save feedback shows
    /// inside the viewer rather than behind it, or nowhere.
    func testExpandedImageNoticesShowInsideTheViewer() async throws {
        _ = NSApplication.shared
        let descriptor = AgentChatAttachmentDescriptor(id: "image", name: "photo.png", mimeType: "image/png", byteCount: 3)
        let theme = Self.paper()
        let preview = AgentMediaPreviewWindow(item: "message", attachments: [descriptor], index: 0,
                                              fetch: { _, _ in throw ModelError("Unavailable") }, theme: theme)
        defer { preview.close() }
        preview.imageActions.fetch = { throw URLError(.cannotDecodeContentData) }
        preview.imageActions.copyImage()
        func shown() -> [String] { preview.notices.subviews.compactMap { ($0 as? NoticeView)?.notice?.message } }
        try await settle { shown().count == 2 }
        XCTAssertEqual(shown().first, "Copying image…")
        XCTAssertTrue(shown().last?.hasPrefix("Could not copy image") == true, "\(shown())")
        Self.assertDrawn(preview.notices, in: theme)
    }

    /// A conversation in a window, with nothing behind it.
    private func conversation(theme: AgentTheme) -> (AgentConversationViewController, NSWindow) {
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        let connection = AgentConnection(session: snapshot.session, project: snapshot.project, provider: .claude,
                                         request: { _ in snapshot }, observe: { AsyncStream { $0.finish() } })
        let conversation = AgentConversationViewController(connection: connection, theme: theme)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = conversation.view
        return (conversation, window)
    }

    /// A diagram drawn in `theme` inside `container`, as a response shows it.
    private func diagram(in container: NSView, theme: AgentTheme) -> AgentResponseDiagram {
        let diagram = AgentResponseDiagram(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        container.addSubview(diagram)
        diagram.update(.diagram("flowchart LR\n  A --> B"), theme: theme, delegate: DiagramTextDelegate())
        diagram.layoutSubtreeIfNeeded()
        return diagram
    }

    /// An expanded diagram closes with its conversation, and once closed the conversation
    /// no longer holds it.
    func testAnExpandedPreviewClosesWithItsConversation() throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { window.close() }
        let surface = conversation.controller.surface
        diagram(in: surface, theme: surface.theme).expandDiagram()
        let preview = try XCTUnwrap(surface.actions.expandedMedia)
        preview.close()
        XCTAssertNil(surface.actions.expandedMedia, "A closed preview is let go")

        diagram(in: surface, theme: surface.theme).expandDiagram()
        let open = try XCTUnwrap(surface.actions.expandedMedia)
        XCTAssertNotNil(open.window?.parent, "It covers the conversation")
        conversation.dispose()
        XCTAssertNil(open.window?.parent, "Disposing the conversation closes it")
        XCTAssertNil(surface.actions.expandedMedia)
    }

    /// A diagram drawn before its conversation's theme was replaced by one with the same
    /// colors still opens in the new theme.
    func testAPreviewOpenedAfterAThemeChangeUsesTheNewTheme() throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { conversation.dispose(); window.close() }
        let surface = conversation.controller.surface
        let drawn = diagram(in: surface, theme: surface.theme)
        let replaced = Self.paper()
        conversation.theme = replaced
        drawn.expandDiagram()
        XCTAssertTrue(surface.actions.expandedMedia?.content.theme === replaced)
    }

    /// A diagram drawn before its conversation's theme was replaced by one with the same
    /// colors is drawn in the new theme when expanded, even after the old one changed.
    func testAnExpandedDiagramIsDrawnInItsOwnersTheme() async throws {
        _ = NSApplication.shared
        let old = Self.paper()
        let (conversation, window) = conversation(theme: old)
        defer { conversation.dispose(); window.close() }
        let surface = conversation.controller.surface
        let drawn = diagram(in: surface, theme: old)
        conversation.theme = Self.paper()
        old.setResolvedScheme(ColorScheme(background: RGBColor(0x101820), foreground: RGBColor(0xE0E0E0)), interface: old.interface)
        drawn.expandDiagram()
        // What the viewer shows, not a render made afterwards.
        let fetch = try XCTUnwrap(surface.actions.expandedMedia?.imageActions.fetch)
        let payload = try await fetch()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: payload))
        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        XCTAssertEqual(corner.redComponent, CGFloat(0xFA) / 255, accuracy: 0.02, "Drawn on the new theme's background, not \(corner)")
        XCTAssertEqual(corner.blueComponent, CGFloat(0xF7) / 255, accuracy: 0.02)
    }

    /// A diagram outside anything that owns its preview lets the preview go once closed.
    func testAPreviewOfADiagramOutsideAConversationIsLetGoWhenClosed() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        diagram(in: container, theme: Self.paper()).expandDiagram()
        let preview = try XCTUnwrap(AgentResponseDiagram.preview)
        preview.close()
        XCTAssertNil(AgentResponseDiagram.preview)
    }

    /// A diagram in a file's preview opens over that preview, follows its theme and closes
    /// with it.
    func testADiagramInAFilePreviewBelongsToThePreview() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { conversation.dispose(); window.close() }
        let controller = conversation.controller, surface = controller.surface
        surface.fetchAttachment = { _, _ in Data("# Notes".utf8) }
        let notes = AgentChatAttachmentDescriptor(id: "notes", name: "notes.md", mimeType: "text/markdown", byteCount: 7)
        surface.onOpenAttachment?("message", notes, false)
        let file = try XCTUnwrap(controller.filePreview)
        diagram(in: file.content, theme: file.content.theme).expandDiagram()
        let expanded = try XCTUnwrap(file.content.expanded)
        XCTAssertNil(surface.actions.expandedMedia, "It isn't the conversation's")

        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        XCTAssertTrue(expanded.content.theme === replaced)
        file.close()
        XCTAssertNil(file.content.expanded, "It closes with the preview")
    }

    /// A diagram in an agent's steps opens over those steps, follows their theme and closes
    /// with them.
    func testADiagramInAnAgentsStepsBelongsToTheSteps() throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { conversation.dispose(); window.close() }
        let controller = conversation.controller, surface = controller.surface
        controller.conversationRequest = { _ in throw URLError(.cannotDecodeContentData) }
        controller.openSubagentSteps(AgentSubagent(id: "agent", toolUseID: "task", description: "Explore"))
        let steps = try XCTUnwrap(controller.subagentWindows["task"])
        defer { steps.close() }
        // Within the steps' transcript, as one of its own diagrams is.
        func transcript(in view: NSView) -> AgentTranscriptDocument? {
            view as? AgentTranscriptDocument ?? view.subviews.lazy.compactMap { transcript(in: $0) }.first
                ?? (view as? NSScrollView)?.documentView.flatMap { transcript(in: $0) }
        }
        let nested = try XCTUnwrap(transcript(in: steps.content))
        diagram(in: nested, theme: steps.theme).expandDiagram()
        let expanded = try XCTUnwrap(steps.content.expanded)
        XCTAssertNil(surface.actions.expandedMedia, "It isn't the conversation's")

        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        XCTAssertTrue(expanded.content.theme === replaced)
        steps.close()
        XCTAssertNil(steps.content.expanded, "It closes with the steps")
    }

    /// What is open over a conversation follows its theme as the theme changes in place, as
    /// for the system appearance, and not only when it is replaced.
    func testWhatIsOpenOverAConversationFollowsItsThemeChangingInPlace() async throws {
        _ = NSApplication.shared
        let theme = Self.paper()
        let (conversation, window) = conversation(theme: theme)
        defer { conversation.dispose(); window.close() }
        window.orderFront(nil)
        let pane = conversation.controller, surface = pane.surface
        pane.refresh()
        try await settle { pane.snapshot != nil }
        surface.fetchAttachment = { _, _ in Data("# Notes".utf8) }
        let notes = AgentChatAttachmentDescriptor(id: "notes", name: "notes.md", mimeType: "text/markdown", byteCount: 7)
        surface.onOpenAttachment?("message", notes, false)
        let file = try XCTUnwrap(pane.filePreview)
        defer { file.close() }
        XCTAssertEqual(file.window?.appearance?.name, .aqua, "A file's preview takes the conversation's appearance")
        pane.conversationRequest = { _ in throw URLError(.cannotDecodeContentData) }
        pane.openSubagentSteps(AgentSubagent(id: "agent", toolUseID: "task", description: "Explore"))
        let steps = try XCTUnwrap(pane.subagentWindows["task"])
        defer { steps.close() }
        pane.loadHistory = { AgentHistoryReply(entries: []) }
        pane.showHistory()
        try await settle { pane.historyPicker != nil }
        let history = try XCTUnwrap(pane.historyPicker)
        defer { history.close() }
        let draft = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID()).txt")
        try Data("Draft".utf8).write(to: draft)
        defer { try? FileManager.default.removeItem(at: draft) }
        pane.attachFiles([draft])
        try await settle { pane.draftAttachments.count == 1 }
        surface.attachmentStrip.onPreview?(try XCTUnwrap(pane.draftAttachments.first?.id))
        let attachment = try XCTUnwrap(pane.attachmentPreview)
        defer { attachment.close() }
        let indicator = surface.contextIndicator
        indicator.sendAction(indicator.action, to: indicator.target)
        let details = try XCTUnwrap(indicator.details)
        defer { indicator.popover?.close() }
        XCTAssertEqual(indicator.popover?.appearance?.name, .aqua, "The context details take the conversation's appearance")
        let editor = AgentTextEditorSheet(title: "Edit", detail: "", text: "Kept", theme: theme)

        theme.setResolvedScheme(ColorScheme(background: RGBColor(0x101820), foreground: RGBColor(0xE8E4DC)), interface: theme.interface)
        XCTAssertEqual(theme.nsAppearance?.name, .darkAqua)
        try await settle { steps.window?.appearance?.name == .darkAqua && history.window?.appearance?.name == .darkAqua }
        XCTAssertEqual(file.window?.appearance?.name, .darkAqua, "A file's preview")
        XCTAssertEqual(steps.window?.appearance?.name, .darkAqua, "An agent's steps")
        XCTAssertEqual(steps.message.textColor, theme.fgDim)
        XCTAssertEqual(history.window?.appearance?.name, .darkAqua, "Past conversations")
        XCTAssertEqual(history.note.textColor, theme.fgDim)
        XCTAssertEqual(details.heading.textColor, theme.fg, "The context details")
        XCTAssertEqual(details.detail.textColor, theme.fgMuted)
        XCTAssertEqual(indicator.popover?.appearance?.name, .darkAqua)
        let title = try XCTUnwrap(attachment.contentViewController?.view.subviews.lazy.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(title.textColor, theme.fg, "A draft attachment's preview")
        XCTAssertEqual(editor.alert.window.appearance?.name, .darkAqua, "An editor")
        XCTAssertEqual(editor.editor.textColor, theme.fg)
        XCTAssertEqual(editor.editor.string, "Kept", "Keeping what was typed")

        // Replaced, the context details and the file's preview follow too.
        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        XCTAssertTrue(details.background.theme === replaced)
        XCTAssertEqual(details.heading.textColor, replaced.fg)
        XCTAssertEqual(indicator.popover?.appearance?.name, .aqua)
        XCTAssertEqual(file.window?.appearance?.name, .aqua)
    }

    /// A confirmation open over a conversation follows its theme, and ends with the
    /// conversation, which sends nothing for it after.
    func testAConfirmationEndsWithItsConversation() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { window.close() }
        window.orderFront(nil)
        let pane = conversation.controller, requests = Requests()
        pane.conversationRequest = { request in requests.values.append(request); throw URLError(.cannotDecodeContentData) }
        pane.revertTurn(Self.checkpoint, paths: nil)
        try await settle { !pane.sheets.isEmpty }
        let sheet = try XCTUnwrap(pane.sheets.first?.alert)
        let dark = Self.paper(foreground: 0xE8E4DC, background: 0x101820)
        conversation.theme = dark
        XCTAssertEqual(sheet.window.appearance?.name, .darkAqua, "In a replaced theme")
        dark.setResolvedScheme(ColorScheme(background: RGBColor(0xFAFAF7), foreground: RGBColor(0x202020)), interface: dark.interface)
        try await settle { sheet.window.appearance?.name == .aqua }
        XCTAssertEqual(sheet.window.appearance?.name, .aqua, "And as it changes in place")
        conversation.dispose()
        XCTAssertTrue(pane.sheets.isEmpty)
        XCTAssertNil(sheet.window.sheetParent, "Ended with its conversation")
        try await settle()
        XCTAssertTrue(requests.values.isEmpty, "Nothing sent for a conversation that went")
        XCTAssertTrue(pane.surface.actions.windowsClosed, "Its windows close too")
        XCTAssertEqual((pane.surface.actions.project as? AgentHostActions)?.closed, true, "And the host's previews")
    }

    /// A revert confirmed only after its conversation went sends nothing.
    func testARevertConfirmedAfterItsConversationWentSendsNothing() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { window.close() }
        let pane = conversation.controller, requests = Requests(), gate = Gate()
        pane.conversationRequest = { request in requests.values.append(request); throw URLError(.cannotDecodeContentData) }
        pane.confirmDestructive = { _, _, _ in
            gate.entered = true
            while !gate.open { try? await Task.sleep(for: .milliseconds(10)) }
            return true
        }
        pane.revertTurn(Self.checkpoint, paths: nil)
        try await settle { gate.entered }
        conversation.dispose()
        gate.open = true
        try await settle()
        XCTAssertTrue(requests.values.isEmpty)
    }

    /// A revert of files changed since its turn, confirmed only after its conversation went,
    /// sends nothing more.
    func testARevertAnywayConfirmedAfterItsConversationWentSendsNothing() async throws {
        _ = NSApplication.shared
        let (conversation, window) = conversation(theme: Self.paper())
        defer { window.close() }
        let pane = conversation.controller, requests = Requests(), gate = Gate()
        pane.conversationRequest = { request in
            requests.values.append(request)
            return .revert(AgentRevertReply(conflicts: ["a.swift"]))
        }
        var asked = 0
        pane.confirmDestructive = { _, _, _ in
            asked += 1
            guard asked > 1 else { return true }
            gate.entered = true
            while !gate.open { try? await Task.sleep(for: .milliseconds(10)) }
            return true
        }
        pane.revertTurn(Self.checkpoint, paths: nil)
        try await settle { gate.entered }
        XCTAssertEqual(requests.values.count, 1, "The first try found the later changes")
        conversation.dispose()
        gate.open = true
        try await settle()
        XCTAssertEqual(requests.values.count, 1, "No forced revert for a conversation that went")
    }

    /// A project file's preview still loading when its conversation goes opens no window.
    func testAProjectFilePreviewLoadingAsItsConversationGoesOpensNoWindow() async throws {
        _ = NSApplication.shared
        let gate = Gate()
        var services = AgentHostServices(directory: { "/tmp" }, isLocal: { true })
        services.supportsRangedReads = { false }
        services.readFile = { request in
            switch request.action {
            case .stat(let path): return .info(FileInfo(name: path, path: path, isDirectory: false, size: 5))
            case .readBytes(let path):
                gate.entered = true
                while !gate.open { try await Task.sleep(for: .milliseconds(10)) }
                return .bytes(FileBytes(path: path, bytes: Data("Notes".utf8)))
            default: throw URLError(.unsupportedURL)
            }
        }
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.render(snapshot)
        let host = AgentHostActions(surface: surface, session: snapshot.session, services: services)
        let loading = Task { try await host.previewFile("notes.txt") }
        try await settle { gate.entered }
        host.close()
        gate.open = true
        try await loading.value
        XCTAssertNil(host.preview)
    }

    /// A theme of the conversation's own, unlike the shared one.
    private static func paper(foreground: UInt32 = 0x202020, background: UInt32 = 0xFAFAF7) -> AgentTheme {
        let scheme = ColorScheme(background: RGBColor(background), foreground: RGBColor(foreground))
        return AgentTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Paper", scheme: scheme)]), darkTheme: "Paper", lightTheme: "Paper",
                          systemIsDark: false)
    }

    /// Every notice in `stack` draws with `theme`, not the shared one.
    private static func assertDrawn(_ stack: NoticeStack, in theme: AgentTheme, file: StaticString = #filePath, line: UInt = #line) {
        let views = stack.subviews.compactMap { $0 as? NoticeView }
        XCTAssertFalse(views.isEmpty, file: file, line: line)
        XCTAssertNotEqual(theme.fg, AgentTheme.shared.fg, "The themes must differ to tell them apart", file: file, line: line)
        for view in views {
            XCTAssertTrue(view.theme === theme, file: file, line: line)
            view.updateLayer()
            XCTAssertEqual(view.layer?.borderColor, theme.fg(alpha: 0.08).cgColor, file: file, line: line)
        }
    }

    /// A host that shows no notices and has no notice stack of its own still sees an
    /// inline image's copy feedback, in the conversation.
    func testWithoutHostOrWindowNoticesTheConversationShowsItsOwn() async throws {
        _ = NSApplication.shared
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        let connection = AgentConnection(session: snapshot.session, project: snapshot.project, provider: .claude,
                                         request: { _ in snapshot }, observe: { AsyncStream { $0.finish() } })
        let theme = Self.paper()
        let conversation = AgentConversationViewController(connection: connection, theme: theme)
        defer { conversation.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = conversation.view
        let surface = conversation.controller.surface
        let image = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        surface.addSubview(image)
        let actions = AgentImageActions(name: "photo.png")
        actions.view = image
        actions.fetch = { throw URLError(.cannotDecodeContentData) }
        actions.copyImage()
        func shown() -> [String] { surface.ownNotices().subviews.compactMap { ($0 as? NoticeView)?.notice?.message } }
        try await settle { shown().count == 2 }
        XCTAssertEqual(shown().first, "Copying image…")
        XCTAssertTrue(shown().last?.hasPrefix("Could not copy image") == true, "\(shown())")
        Self.assertDrawn(surface.ownNotices(), in: theme)

        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        surface.theme = replaced
        Self.assertDrawn(surface.ownNotices(), in: replaced)
    }

    /// An expanded image follows its conversation into a replaced theme, notices and all.
    func testAnOpenViewerFollowsItsConversationIntoANewTheme() async throws {
        _ = NSApplication.shared
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        let connection = AgentConnection(session: snapshot.session, project: snapshot.project, provider: .claude,
                                         request: { _ in snapshot }, observe: { AsyncStream { $0.finish() } })
        let conversation = AgentConversationViewController(connection: connection, theme: Self.paper())
        defer { conversation.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = conversation.view
        let surface = conversation.controller.surface
        try surface.actions.previewMarkdownMedia([AgentMarkdownMedia(source: "https://example.invalid/photo.png", kind: .image)], index: 0)
        let preview = try XCTUnwrap(surface.actions.expandedMedia)
        defer { preview.close() }
        preview.imageActions.fetch = { throw URLError(.cannotDecodeContentData) }
        preview.imageActions.copyImage()
        try await settle { preview.notices.subviews.contains { $0 is NoticeView } }

        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        XCTAssertTrue(preview.content.theme === replaced, "The viewer draws in the new theme")
        Self.assertDrawn(preview.notices, in: replaced)
    }

    /// An attachment's viewer, a file's preview, a diagram's, and the windows showing a
    /// turn's or a tool's changes or an agent's steps all follow their conversation into a
    /// replaced theme, and so do notices shown after it.
    func testEveryOpenPreviewFollowsItsConversationIntoANewTheme() async throws {
        _ = NSApplication.shared
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        let connection = AgentConnection(session: snapshot.session, project: snapshot.project, provider: .claude,
                                         request: { _ in snapshot }, observe: { AsyncStream { $0.finish() } })
        let conversation = AgentConversationViewController(connection: connection, theme: Self.paper())
        defer { conversation.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = conversation.view
        let controller = conversation.controller, surface = controller.surface
        surface.fetchAttachment = { _, _ in throw URLError(.cannotDecodeContentData) }
        let image = AgentChatAttachmentDescriptor(id: "photo", name: "photo.png", mimeType: "image/png", byteCount: 3)
        surface.onPreviewAttachments?("message", [image], 0)
        let viewer = try XCTUnwrap(controller.mediaPreview)
        defer { viewer.close() }
        let notes = AgentChatAttachmentDescriptor(id: "notes", name: "notes.txt", mimeType: "text/plain", byteCount: 5)
        surface.onOpenAttachment?("message", notes, false)
        let file = try XCTUnwrap(controller.filePreview)
        defer { file.close() }
        let diagram = AgentResponseDiagram(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        surface.addSubview(diagram)
        let delegate = DiagramTextDelegate()
        diagram.update(.diagram("flowchart LR\n  A --> B"), theme: surface.theme, delegate: delegate)
        diagram.layoutSubtreeIfNeeded()
        diagram.expandDiagram()
        let expanded = try XCTUnwrap(surface.actions.expandedMedia, "The diagram's preview is the conversation's")

        controller.loadCheckpoint = { _ in throw URLError(.cannotDecodeContentData) }
        surface.onOpenCheckpoint?("turn", nil)
        let changes = try XCTUnwrap(controller.checkpointWindows.values.first)
        defer { changes.close() }
        var edit = AgentToolActivity(name: "Edit", category: .edit, status: .completed, filePaths: ["a.swift"], presentation: .fileChange)
        edit.fileChanges = [.init(path: "a.swift", diff: "@@ -1 +1 @@\n-old\n+new\n")]
        surface.onOpenToolDiff?("edit", edit)
        let toolDiff = try XCTUnwrap(controller.toolDiffWindows["edit"]?.window)
        defer { toolDiff.close() }
        controller.conversationRequest = { _ in throw URLError(.cannotDecodeContentData) }
        controller.openSubagentSteps(AgentSubagent(id: "agent", toolUseID: "task", description: "Explore"))
        let steps = try XCTUnwrap(controller.subagentWindows["task"])
        defer { steps.close() }
        changes.showComments()
        let comments = try XCTUnwrap(changes.commentPicker)
        defer { comments.close() }
        controller.loadHistory = { AgentHistoryReply(entries: []) }
        controller.showHistory()
        try await settle { controller.historyPicker != nil }
        let history = try XCTUnwrap(controller.historyPicker)
        defer { history.close() }
        surface.showOutline()
        let outline = try XCTUnwrap(surface.outlinePicker)
        defer { outline.close() }

        let replaced = Self.paper(foreground: 0x7A1F1F, background: 0xF4EDE4)
        conversation.theme = replaced
        XCTAssertTrue(viewer.content.theme === replaced)
        XCTAssertTrue(file.content.theme === replaced)
        XCTAssertTrue(file.icon.theme === replaced, "The file's mark in the title bar too")
        XCTAssertTrue(expanded.content.theme === replaced)
        XCTAssertTrue(changes.theme === replaced, "A turn's changes")
        XCTAssertTrue(toolDiff.theme === replaced, "A tool's changes")
        XCTAssertTrue(steps.theme === replaced, "An agent's steps")
        XCTAssertTrue(comments.theme === replaced, "A turn's review comments")
        XCTAssertTrue(history.theme === replaced, "Past conversations")
        XCTAssertTrue(outline.theme === replaced, "The conversation's prompts")
        viewer.imageActions.fetch = { throw URLError(.cannotDecodeContentData) }
        viewer.imageActions.copyImage()
        try await settle { viewer.notices.subviews.contains { $0 is NoticeView } }
        Self.assertDrawn(viewer.notices, in: replaced)

        comments.close()
        changes.editComment(AgentReviewComment(checkpoint: "turn", path: "a.swift", old: false, firstLine: 1, lastLine: 1,
                                               source: "new", text: "Keep this"), existing: false)
        let editor = try XCTUnwrap(changes.commentEditor)
        defer { editor.close() }
        let night = Self.paper(foreground: 0xE8E8E8, background: 0x1C1C1E)
        conversation.theme = night
        XCTAssertEqual(editor.editor.backgroundColor, night.card, "A review comment being written")
        XCTAssertEqual(editor.editor.string, "Keep this", "Keeping what was typed")
    }

    /// Tables and agents' reports draw branded links in the conversation's theme too.
    func testTablesAndReportsDrawLinkMarksInTheConversationsTheme() {
        _ = NSApplication.shared
        let paper = ColorScheme(background: RGBColor(0xFAFAF7), foreground: RGBColor(0x202020))
        let theme = AgentTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Paper", scheme: paper)]), darkTheme: "Paper", lightTheme: "Paper", systemIsDark: false)
        let response = AgentResponseView(frame: .zero)
        response.setContent("| Link |\n|---|\n| [PR](https://github.com/example/project/pull/1) |", theme: theme)
        _ = response.height(for: 400)
        let table = response.sectionViews.compactMap { $0 as? AgentResponseTable }.first
        XCTAssertTrue(table?.text.linkIconTheme === theme, "The table's link marks use the conversation's theme")
        let detail = AgentToolDisclosure(frame: .zero)
        detail.refresh(theme: theme)
        XCTAssertTrue(detail.linkTextViews.allSatisfy { $0.linkIconTheme === theme })
    }
}
