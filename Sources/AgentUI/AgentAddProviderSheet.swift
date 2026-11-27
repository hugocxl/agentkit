import AgentCore
import AppKit

/// The Add Provider form: the kind of agent, its label, ID and accent color, then how it
/// runs and signs in. What the backend finds for the form as it stands, such as the
/// installed CLI and who it is signed in as, shows as it goes. Another provider of a kind
/// gets a folder of its own, so it can sign in to another account.
@MainActor
final class AgentAddProviderSheet: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private(set) var draft: AgentProviderDraft
    private let state: AgentProvidersState
    private let theme: AgentTheme
    private let probe: (@Sendable (AgentProviderConfig) async -> AgentProviderHealth?)?
    private let add: (AgentProviderConfig) -> Void
    private var health: AgentProviderHealth?
    private var checking = false
    private var probeTask: Task<Void, Never>?

    let kind = NSPopUpButton()
    let label = NSTextField()
    let identifier = NSTextField()
    private let accent = NSPopUpButton()
    let executable = NSTextField()
    let home = NSTextField()
    private let homeRow = NSStackView()
    private let homeTitle = NSTextField(labelWithString: "")
    private let homeNote = NSTextField(wrappingLabelWithString: "")
    let signInMethod = NSSegmentedControl(labels: ["Account", "API key"], trackingMode: .selectOne, target: nil, action: nil)
    private let signInRow = NSStackView()
    let apiKey = NSSecureTextField()
    private let apiKeyRow = NSStackView()
    private let apiKeyTitle = NSTextField(labelWithString: "")
    let arguments = NSTextField()
    private let argumentsNote = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    let addButton = NSButton(title: "Add Provider", target: nil, action: nil)
    private let kinds: [AgentChatProvider]

    init(state: AgentProvidersState, theme: AgentTheme, probe: (@Sendable (AgentProviderConfig) async -> AgentProviderHealth?)?,
         add: @escaping (AgentProviderConfig) -> Void) {
        self.state = state
        self.theme = theme
        self.probe = probe
        self.add = add
        // The kinds the backend runs, ones not added yet first.
        let added = Set(state.settings.providers.map(\.kind))
        kinds = state.kinds.filter { !added.contains($0) } + state.kinds.filter { added.contains($0) }
        draft = AgentProviderDraft(kind: kinds.first ?? .claude, settings: state.settings)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
        fill()
        checkDraft(after: .zero)
    }

    // MARK: Layout

    private func build() {
        window.title = "Add Provider"
        for provider in kinds {
            kind.addItem(withTitle: provider.name)
            kind.lastItem?.representedObject = provider.rawValue
            if let logo = AgentLogo.image(for: provider, size: 16, theme: theme) {
                kind.lastItem?.image = logo
            }
        }
        kind.target = self
        kind.action = #selector(kindChanged)
        kind.setAccessibilityLabel("Agent")

        for (field, placeholder, monospaced) in [(label, "e.g. Work or Personal", false), (identifier, "", true),
                                                 (executable, "", true), (home, "", true), (apiKey, "Key", true), (arguments, "", true)] {
            field.placeholderString = placeholder
            field.delegate = self
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            if monospaced { field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        label.setAccessibilityLabel("Label")
        identifier.setAccessibilityLabel("ID")
        executable.setAccessibilityLabel("Executable")
        home.setAccessibilityLabel("Config folder")
        apiKey.setAccessibilityLabel("API key")
        arguments.setAccessibilityLabel("Launch arguments")

        accent.addItem(withTitle: "None")
        for hex in AgentProviderConfig.accentColors {
            accent.addItem(withTitle: hex)
            accent.lastItem?.representedObject = hex
            accent.lastItem?.image = AgentAccentPopUp.swatch(hex)
        }
        accent.target = self
        accent.action = #selector(accentChanged)
        accent.setAccessibilityLabel("Accent color")

        signInMethod.target = self
        signInMethod.action = #selector(signInChanged)
        signInMethod.setAccessibilityLabel("Sign in with")

        for note in [homeNote, argumentsNote, status, warning, problem] {
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 380
        }
        warning.textColor = .systemOrange
        problem.textColor = .systemRed

        func row(_ title: NSTextField, _ views: [NSView]) -> NSStackView {
            title.alignment = .right
            title.textColor = .secondaryLabelColor
            title.translatesAutoresizingMaskIntoConstraints = false
            title.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            let row = NSStackView(views: [title, column])
            row.alignment = .firstBaseline
            row.spacing = 10
            return row
        }
        let rows: [NSView] = [
            row(NSTextField(labelWithString: "Agent"), [kind]),
            row(NSTextField(labelWithString: "Label"), [label]),
            row(NSTextField(labelWithString: "ID"), [identifier]),
            row(NSTextField(labelWithString: "Accent color"), [accent]),
            row(NSTextField(labelWithString: "Executable"), [executable]),
        ]
        homeRow.addArrangedSubview(row(homeTitle, [home, homeNote]))
        signInRow.addArrangedSubview(row(NSTextField(labelWithString: "Sign in with"), [signInMethod]))
        apiKeyRow.addArrangedSubview(row(apiKeyTitle, [apiKey]))
        let argumentRow = row(NSTextField(labelWithString: "Arguments"), [arguments, argumentsNote])

        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(confirm)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.spacing = 8

        let stack = NSStackView(views: rows + [homeRow, signInRow, apiKeyRow, argumentRow, status, warning, problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        for note in [status, warning, problem] { note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560),
        ])
        window.contentView = content
    }

    /// Shows the draft in the fields.
    private func fill() {
        let spec = draft.kind.spec
        kind.selectItem(at: kinds.firstIndex(of: draft.kind) ?? 0)
        label.stringValue = draft.label
        label.placeholderString = draft.siblings(state.settings).isEmpty ? draft.kind.name : "e.g. Work or Personal"
        identifier.stringValue = draft.id
        accent.select(accent.itemArray.first { ($0.representedObject as? String) == draft.accentColor } ?? accent.itemArray.first)
        executable.stringValue = draft.executable
        executable.placeholderString = spec.executable ?? "e.g. qwen"
        if draft.kind == .codex {
            homeTitle.stringValue = "Account folder"
            home.stringValue = draft.shadowHome
            home.placeholderString = "Empty uses ~/.codex"
            homeNote.stringValue = "Keeps this account's sign-in apart while sharing conversations and skills with ~/.codex."
        } else if let variable = spec.homeVariable {
            homeTitle.stringValue = "Config folder"
            home.stringValue = draft.home
            home.placeholderString = spec.defaultHome ?? ""
            homeNote.stringValue = "\(variable): where \(draft.kind.name) keeps its sign-in and settings. A folder of its own signs in to another account."
        }
        homeRow.isHidden = spec.homeVariable == nil || draft.useAPIKey && draft.kind != .codex
        signInRow.isHidden = spec.apiKeyVariables.isEmpty
        signInMethod.selectedSegment = draft.useAPIKey ? 1 : 0
        apiKeyRow.isHidden = !draft.useAPIKey
        apiKeyTitle.stringValue = draft.apiKeyVariable.isEmpty ? "API key" : draft.apiKeyVariable
        apiKey.stringValue = draft.apiKey
        arguments.stringValue = draft.arguments
        arguments.placeholderString = spec.argumentsExample ?? ""
        argumentsNote.stringValue = AgentProviderSummary.arguments(draft.kind)
        refreshFindings()
    }

    /// The lines that follow what the backend found, and whether the form can be added.
    private func refreshFindings() {
        let found = draft.status(health: health, checking: checking)
        status.stringValue = found.text
        status.textColor = found.problem ? .systemRed : .secondaryLabelColor
        status.isHidden = found.text.isEmpty
        let warned = draft.warning(health: health, state: state)
        warning.stringValue = warned ?? ""
        warning.isHidden = warned == nil
        let error = draft.identityError(state.settings) ?? draft.configError()
        problem.stringValue = error ?? ""
        problem.isHidden = error == nil
        addButton.isEnabled = error == nil
    }

    /// Checks the form as it stands after a pause in typing.
    private func checkDraft(after delay: Duration = .milliseconds(450)) {
        probeTask?.cancel()
        guard let probe, draft.configError() == nil else { health = nil; checking = false; refreshFindings(); return }
        checking = true
        refreshFindings()
        var config = draft.config
        if config.id.isEmpty || !AgentProviderConfig.isValidID(config.id) { config.id = draft.kind.rawValue }
        probeTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await probe(config)
            guard !Task.isCancelled, let self else { return }
            self.health = found
            self.checking = false
            self.refreshFindings()
        }
    }

    // MARK: Editing

    @objc private func kindChanged() {
        guard let raw = kind.selectedItem?.representedObject as? String, let chosen = AgentChatProvider(rawValue: raw) else { return }
        let label = draft.label
        draft.reset(chosen, settings: state.settings)
        if !label.isEmpty { draft.setLabel(label, settings: state.settings) }
        health = nil
        fill()
        checkDraft(after: .zero)
    }

    @objc private func accentChanged() {
        draft.accentColor = accent.selectedItem?.representedObject as? String
    }

    @objc private func signInChanged() {
        draft.useAPIKey = signInMethod.selectedSegment == 1
        fill()
        checkDraft()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case label:
            draft.setLabel(label.stringValue, settings: state.settings)
            identifier.stringValue = draft.id
            if draft.kind == .codex { home.stringValue = draft.shadowHome } else { home.stringValue = draft.home }
        case identifier:
            draft.id = identifier.stringValue
            draft.idEdited = true
        case executable: draft.executable = executable.stringValue
        case home:
            if draft.kind == .codex { draft.shadowHome = home.stringValue } else { draft.home = home.stringValue }
        case apiKey: draft.apiKey = apiKey.stringValue
        case arguments: draft.arguments = arguments.stringValue
        default: return
        }
        field === label || field === identifier ? refreshFindings() : checkDraft()
    }

    @objc private func confirm() {
        guard draft.identityError(state.settings) == nil, draft.configError() == nil else { refreshFindings(); return }
        probeTask?.cancel()
        let config = draft.config
        close()
        add(config)
    }

    @objc private func cancel() {
        probeTask?.cancel()
        close()
    }

    private func close() {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
    }
}
