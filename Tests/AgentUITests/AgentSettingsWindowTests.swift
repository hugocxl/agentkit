import AgentCore
import AppKit
import XCTest
@testable import AgentUI

/// A backend's providers held in memory, recording what agent settings ask of it.
private final class FakeProviders: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AgentProviderSettings
    private var health: [AgentProviderHealth]
    private(set) var writes: [AgentProviderSettings] = []
    private(set) var maintained: [String] = []

    init(_ settings: AgentProviderSettings, health: [AgentProviderHealth] = []) {
        self.settings = settings
        self.health = health
    }

    var state: AgentProvidersState { lock.withLock { AgentProvidersState(settings: settings, health: health) } }
    var writeCount: Int { lock.withLock { writes.count } }

    var management: AgentProviderManagement {
        AgentProviderManagement(
            state: { [self] in state },
            check: { [self] in state },
            write: { [self] next in
                lock.withLock { settings = next; writes.append(next) }
                return state
            },
            maintain: { [self] id, _ in
                lock.withLock { maintained.append(id) }
                return state
            },
            probe: { config in
                AgentProviderHealth(provider: config.id, installed: true, version: "2.1.400", auth: .signedIn,
                                    email: "me@example.com", checkedAt: Date())
            },
            models: { config, _ in
                [AgentModelDescriptor(id: "\(config.id)-fast", title: "Fast", reasoningEfforts: [], isDefault: true),
                 AgentModelDescriptor(id: "\(config.id)-deep", title: "Deep", reasoningEfforts: [.high])]
            })
    }
}

@MainActor
final class AgentSettingsWindowTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Agent settings did not settle")
    }

    private func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { child -> [String] in
            let own = (child as? NSTextField).map { [$0.stringValue] } ?? (child as? NSButton).map { [$0.title] } ?? []
            return own + texts(in: child)
        }
    }

    func testTheWindowListsProvidersAndSavesAPagesEdits() async throws {
        _ = NSApplication.shared
        let claude = AgentProviderConfig.builtIn(.claude)
        let work = AgentProviderConfig(id: "claude-work", kind: .claude, name: "Work", home: "~/.claude-work")
        let behind = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.1", auth: .signedIn, checkedAt: Date(),
                                         versionAdvisory: .init(status: .behindLatest, latestVersion: "2.1.9", canUpdate: true))
        let backend = FakeProviders(AgentProviderSettings(providers: [claude, work]), health: [behind])
        let settings = AgentSettingsWindowController.show(backend.management, provider: "claude-work")
        defer { settings.close() }
        try await wait { settings.state != nil && settings.selectedID == "claude-work" }
        XCTAssertEqual(settings.table.numberOfRows, 2)
        try await wait { self.texts(in: settings.detail).contains("Deep") }
        let page = texts(in: settings.detail)
        XCTAssertTrue(page.contains("Work"))
        XCTAssertTrue(page.contains("claude-work"), "the ID shows on its page")
        XCTAssertTrue(page.contains("Fast (default)"))

        settings.update("claude-work") { $0.models.hidden = ["claude-work-deep"] }
        try await wait { backend.writeCount == 1 }
        XCTAssertEqual(backend.state.settings.provider("claude-work")?.models.hidden, ["claude-work-deep"])

        settings.table.selectRowIndexes([0], byExtendingSelection: false)
        try await wait { settings.selectedID == "claude" && self.texts(in: settings.detail).contains("Update to 2.1.9") }
    }

    func testAnEmptyBackendOffersToAddAProviderAndTheFormAddsIt() async throws {
        _ = NSApplication.shared
        let backend = FakeProviders(AgentProviderSettings())
        let settings = AgentSettingsWindowController.show(backend.management)
        defer { settings.close() }
        try await wait { settings.state != nil && self.texts(in: settings.detail).contains("Add Provider…") }
        XCTAssertEqual(settings.table.numberOfRows, 0, "another backend's providers never show")

        var added: AgentProviderConfig?
        let form = AgentAddProviderSheet(state: backend.state, theme: .shared, probe: backend.management.probe) { added = $0 }
        XCTAssertEqual(form.draft.kind, .claude)
        XCTAssertTrue(form.addButton.isEnabled, "the first provider of a kind needs no label")
        form.label.stringValue = "Personal"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.label))
        XCTAssertEqual(form.identifier.stringValue, "claude-personal")
        form.addButton.performClick(nil)
        XCTAssertEqual(added?.id, "claude-personal")
        XCTAssertEqual(added?.name, "Personal")
    }

    func testAConversationOpensItsBackendsSettingsFromTheModelMenu() async throws {
        _ = NSApplication.shared
        let backend = FakeProviders(AgentProviderSettings(providers: [.builtIn(.claude)]))
        let session = SessionId(), project = ProjectId()
        var connection = AgentConnection(session: session, project: project, provider: .claude, request: { request in
            AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle, revision: 1)
        }, observe: { AsyncStream { $0.finish() } })
        connection.providers = { backend.state }
        connection.providerManagement = backend.management
        let conversation = AgentConversationViewController(connection: connection)
        defer { conversation.dispose() }
        conversation.refresh()
        try await wait { conversation.controller.surface.model.itemArray.contains { $0.title == "Agent Settings…" } }
        XCTAssertTrue(conversation.showAgentSettings())
        try await wait { NSApp.windows.contains { $0.title == "Agent Settings" && $0.isVisible } }
        NSApp.windows.first { $0.title == "Agent Settings" }?.close()
    }
}
