import AppKit
import AgentCore
import AgentRuntime
import AgentUI

@MainActor
final class ExampleApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var conversation: AgentConversationViewController?
    private var workspace: AgentWorkspace?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = CommandLine.arguments
            func argument(_ name: String) -> String? {
                guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            var connection: AgentConnection
            if let providerName = argument("--provider") {
                guard let provider = AgentChatProvider(rawValue: providerName) else { throw ModelError("Choose --provider codex or --provider claude.") }
                let directory = URL(fileURLWithPath: argument("--directory") ?? FileManager.default.currentDirectoryPath)
                let storage = URL(fileURLWithPath: argument("--storage") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentKit Example").path)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                let identity = storage.appendingPathComponent("example.json")
                let saved: Identity
                if FileManager.default.fileExists(atPath: identity.path) {
                    saved = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identity))
                    guard saved.directory == directory.standardizedFileURL.path else {
                        throw ModelError("This storage folder belongs to another working directory. Supply a separate --storage folder.")
                    }
                } else {
                    saved = Identity(project: ProjectId(), session: SessionId(), directory: directory.standardizedFileURL.path)
                    try JSONEncoder().encode(saved).write(to: identity, options: .atomic)
                }
                let appTools: AgentToolConfiguration? = arguments.contains("--app-tools") ? AgentToolConfiguration([
                    .init(name: "set_window_title", description: "Change the example application's window title.",
                          inputSchema: ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]])
                ]) { @MainActor [weak self] call in
                    guard !Task.isCancelled, let window = self?.window,
                          let title = call.arguments["title"]?.string, !title.isEmpty, title.count <= 120 else {
                        return .failure("Supply a title between 1 and 120 characters.")
                    }
                    window.title = title
                    return .init(text: "Window title changed to \(title).")
                } : nil
                let workspace = try AgentWorkspace(workingDirectory: directory, storageDirectory: storage, project: saved.project,
                    instructions: appTools == nil ? nil : "You control this example application through its registered tools.", tools: appTools)
                self.workspace = workspace
                connection = workspace.connect(provider: provider, session: saved.session)
            } else {
                let demo = DemoConversation()
                connection = AgentConnection(session: demo.session, project: demo.project, provider: .codex,
                                             request: { try await demo.handle($0) }, observe: { demo.observations.stream(session: demo.session) })
                connection.capabilities = []
            }
            let theme = AgentTheme()
            theme.followSystem()
            let controller = AgentConversationViewController(connection: connection, theme: theme)
            conversation = controller
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = workspace == nil ? "AgentKit — Offline Demo" : "AgentKit — \(connection.provider.name)"
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            self.window = window
            let menu = NSMenu()
            let appMenu = NSMenuItem(); menu.addItem(appMenu); appMenu.submenu = NSMenu()
            appMenu.submenu?.addItem(withTitle: "Quit AgentKit Example", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
            for (name, action, key) in [("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
                edit.submenu?.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
            }
            NSApplication.shared.mainMenu = menu
            NSApplication.shared.activate(ignoringOtherApps: true)
            controller.refresh(); controller.focusComposer()
        } catch {
            let alert = NSAlert(error: error); alert.runModal(); NSApplication.shared.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task { [self] in
            do { try await conversation?.flushDraft() }
            catch { terminating = false; NSAlert(error: error).runModal(); return }
            conversation?.dispose()
            let workspace = workspace
            await Task.detached { workspace?.shutdown() }.value
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    private struct Identity: Codable {
        var project: ProjectId
        var session: SessionId
        var directory: String
    }
}

/// An offline transport example: no CLI, credentials, network requests, or model usage.
actor DemoConversation {
    nonisolated let session = SessionId()
    nonisolated let project = ProjectId()
    nonisolated let observations = AgentChangeBroadcaster()
    private var snapshot: AgentChatSnapshot
    private var generation = UUID()
    init() {
        snapshot = AgentChatSnapshot(session: session, project: project, provider: .codex, revision: 1, items: [
            .init(kind: .user, text: "Show me the native conversation interface."),
            .init(kind: .assistant, text: """
            ## A conversation in your app
            This is **AgentKit's offline demo**. The transcript, composer, code blocks, tables, and diagrams are native AppKit views.

            ```swift
            let connection = workspace.connect(provider: .codex)
            let conversation = AgentConversationViewController(connection: connection)
            window.contentViewController = conversation
            ```

            | Module | Responsibility |
            | --- | --- |
            | AgentCore | Shared models and transport |
            | AgentRuntime | Local CLI conversations |
            | AgentUI | Native conversation interface |

            Type a message below to try streaming. To use an installed CLI, launch the example with `--provider codex` or `--provider claude`.
            """)])
    }
    func handle(_ request: AgentChatRequest) throws -> AgentChatSnapshot {
        switch request {
        case .create, .read: return snapshot
        case .submit(_, let prompt): start(prompt.text)
        case .send(_, let text, _, _, _, _, _): start(text)
        case .interrupt: generation = UUID(); snapshot.status = .idle; publish()
        case .setPlan(_, let enabled): snapshot.planMode = enabled; publish()
        case .setAccess(_, let access): snapshot.accessMode = access; publish()
        case .close: generation = UUID(); snapshot.status = .closed; publish()
        default: throw ModelError("This is an offline UI demo. Launch with --provider to use a real agent.")
        }
        return snapshot
    }
    private func start(_ text: String) {
        generation = UUID()
        let current = generation
        snapshot.items.append(.init(kind: .user, text: text))
        let id = UUID().uuidString
        snapshot.items.append(.init(id: id, kind: .assistant, text: "", isComplete: false))
        snapshot.status = .working; publish()
        Task {
            for word in "Your message arrived through the connection interface. A real provider streams into this same native conversation view. No model was called in this demo.".split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(55))
                guard current == generation, let index = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
                snapshot.items[index].text += String(word) + " "
                publish()
            }
            guard current == generation, let index = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
            snapshot.items[index].isComplete = true; snapshot.status = .idle; publish()
        }
    }
    private func publish() {
        snapshot.revision += 1
        observations.publish(.init(session: session, revision: snapshot.revision))
    }
}

@main
struct ExampleMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = ExampleApp()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
