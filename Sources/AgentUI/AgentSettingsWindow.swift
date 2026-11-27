import AgentCore
import AppKit

/// Agent settings in a window of their own: the providers a backend runs, with each one's
/// status, CLI, sign-in, folders, launch arguments, variables and models, and the form that
/// adds another. It works through an `AgentProviderManagement`, so it serves a local
/// `AgentWorkspace` and a remote backend alike.
@MainActor
public final class AgentSettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: AgentSettingsWindowController?

    /// Shows the settings window, reusing the open one, on `provider`'s page when one is
    /// named, or with the Add Provider form. `runCommand` runs a provider's sign-in where
    /// the person can type, such as the host's terminal; without it Terminal opens.
    @discardableResult
    public static func show(_ management: AgentProviderManagement, provider: String? = nil, addProvider: Bool = false,
                            theme: AgentTheme? = nil, runCommand: ((String) -> Void)? = nil) -> AgentSettingsWindowController {
        let controller = shared ?? AgentSettingsWindowController()
        shared = controller
        controller.configure(management, theme: theme ?? .shared, runCommand: runCommand)
        controller.forgetBackend()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.reload(select: provider, thenAdd: addProvider)
        return controller
    }

    private var management: AgentProviderManagement?
    private var theme: AgentTheme = .shared
    private var runCommand: ((String) -> Void)?
    private(set) var state: AgentProvidersState?
    private(set) var selectedID: String?
    private var models: [String: [AgentModelDescriptor]] = [:]
    private var modelsUnavailable = Set<String>()
    private var error: String?
    private var checking = false
    private var poll: Task<Void, Never>?
    private var addSheet: AgentAddProviderSheet?
    /// The detail last built, so a refresh that changes nothing leaves the fields alone.
    private var shownSignature: String?
    private var rebuildPending = false
    private var variableName = ""
    private var variableValue = ""
    private var customModel = ""

    let table = NSTableView()
    private let listScroll = NSScrollView()
    private let detailScroll = NSScrollView()
    let detail = AgentSettingsFlippedView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let checkButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let checkedLabel = NSTextField(labelWithString: "")
    private let intervalPopUp = NSPopUpButton()
    private static let intervals: [(String, Int)] = [("Every 5 minutes", 300), ("Every 15 minutes", 900),
                                                      ("Every hour", 3600), ("Only when asked", 0)]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Settings"
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentKit.AgentSettings")
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    /// Drops what another backend's providers showed, so reopening never shows them.
    private func forgetBackend() {
        state = nil
        selectedID = nil
        models = [:]
        modelsUnavailable = []
        error = nil
        shownSignature = nil
        reloadList()
        rebuildDetail(force: true)
    }

    private func configure(_ management: AgentProviderManagement, theme: AgentTheme, runCommand: ((String) -> Void)?) {
        self.management = management
        self.theme = theme
        self.runCommand = runCommand
        startPolling()
    }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: .init("provider"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Providers")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        for (button, symbol, label, action) in [(addButton, "plus", "Add Provider", #selector(addProvider)),
                                                (removeButton, "minus", "Remove Provider", #selector(removeSelected))] {
            button.bezelStyle = .smallSquare
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        checkButton.target = self
        checkButton.action = #selector(checkNow)
        checkButton.controlSize = .small
        checkedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkedLabel.textColor = .secondaryLabelColor
        checkedLabel.lineBreakMode = .byTruncatingTail
        intervalPopUp.controlSize = .small
        intervalPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intervalPopUp.addItems(withTitles: Self.intervals.map(\.0))
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged)
        intervalPopUp.toolTip = "How often each provider's version and sign-in are checked"

        let buttons = NSStackView(views: [addButton, removeButton, NSView(), checkButton])
        buttons.spacing = 0
        let footer = NSStackView(views: [buttons, intervalPopUp, checkedLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        let sidebar = NSStackView(views: [listScroll, footer])
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        listScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
        footer.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true

        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(sidebar)

        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(effect)
        content.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.topAnchor.constraint(equalTo: content.topAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: 250),
            sidebar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: effect.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: effect.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: content.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])
    }

    // MARK: Loading and saving

    var providers: [AgentProviderConfig] { state?.settings.providers ?? [] }
    var selected: AgentProviderConfig? { providers.first { $0.id == selectedID } }

    /// Reads the backend's providers again, keeping or choosing the selection.
    func reload(select id: String? = nil, thenAdd: Bool = false) {
        guard let management else { return }
        Task { [weak self] in
            do {
                let state = try await management.state()
                self?.apply(state, select: id)
                if thenAdd { self?.addProvider() }
            } catch {
                self?.fail(error)
            }
        }
    }

    private func apply(_ state: AgentProvidersState, select id: String? = nil) {
        let previous = self.state
        self.state = state
        if let id, state.settings.provider(id) != nil { selectedID = id }
        if selectedID == nil || state.settings.provider(selectedID) == nil { selectedID = state.settings.providers.first?.id }
        if previous?.settings != state.settings {
            NotificationCenter.default.post(name: .agentProviderSettingsDidChange, object: nil)
        }
        reloadList()
        if let selected, models[selected.id] == nil, !modelsUnavailable.contains(selected.id) { loadModels(selected.id, refresh: false) }
        rebuildDetail()
    }

    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        rebuildDetail(force: true)
    }

    /// Saves `change` to the backend's providers.
    func save(_ change: (inout AgentProviderSettings) -> Void) {
        guard let management, var settings = state?.settings else { return }
        change(&settings)
        do { try settings.validate() } catch {
            self.error = "That setting isn't valid. Check names, folders and numbers."
            rebuildDetail(force: true)
            return
        }
        error = nil
        Task { [weak self] in
            do {
                let state = try await management.write(settings)
                self?.apply(state)
            } catch {
                self?.fail(error)
            }
        }
    }

    func update(_ id: String, _ change: @escaping (inout AgentProviderConfig) -> Void) {
        save { settings in
            guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.providers[index])
        }
    }

    private func loadModels(_ id: String, refresh: Bool) {
        guard let load = management?.models, let config = providers.first(where: { $0.id == id }) else { return }
        modelsUnavailable.remove(id)
        Task { [weak self] in
            do {
                let found = try await load(config, refresh)
                self?.models[id] = found
            } catch {
                self?.modelsUnavailable.insert(id)
            }
            if self?.selectedID == id { self?.rebuildDetail() }
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                // Quickly while something runs or a provider awaits its first check.
                let state = self?.state
                let unchecked = state.map { state in state.settings.providers.contains { $0.enabled && state.health($0.id) == nil } } ?? true
                let busy = state?.maintenance.contains(where: \.isRunning) == true || self?.checking == true || unchecked
                try? await Task.sleep(for: .seconds(busy ? 1.5 : 10))
                guard let self, !Task.isCancelled, self.window?.isVisible == true, let management = self.management else { continue }
                if let state = try? await management.state() { self.apply(state) }
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        poll?.cancel()
        poll = nil
        addSheet = nil
    }

    // MARK: Actions

    @objc func addProvider() {
        guard let window, window.attachedSheet == nil, let state else { return }
        let sheet = AgentAddProviderSheet(state: state, theme: theme, probe: management?.probe) { [weak self] config in
            self?.selectedID = config.id
            self?.save { $0.providers.append(config) }
        }
        addSheet = sheet
        window.beginSheet(sheet.window) { [weak self] _ in self?.addSheet = nil }
    }

    @objc private func removeSelected() {
        guard let selected else { return }
        confirmRemove(selected)
    }

    private func confirmRemove(_ provider: AgentProviderConfig) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(provider.title)”?"
        alert.informativeText = "Its settings are deleted. Conversations that use it stay but can't continue."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.save { $0.providers.removeAll { $0.id == provider.id } }
        }
    }

    @objc private func checkNow() {
        guard let management, !checking else { return }
        checking = true
        updateFooter()
        Task { [weak self] in
            do {
                let state = try await management.check()
                self?.checking = false
                self?.apply(state)
            } catch {
                self?.checking = false
                self?.fail(error)
            }
            self?.updateFooter()
        }
    }

    @objc private func intervalChanged() {
        let interval = Self.intervals[max(0, intervalPopUp.indexOfSelectedItem)].1
        save { $0.healthCheckInterval = interval }
    }

    private func maintain(_ id: String, _ action: AgentProviderMaintenance.Action) {
        guard let management else { return }
        Task { [weak self] in
            do { self?.apply(try await management.maintain(id, action)) } catch { self?.fail(error) }
        }
    }

    private func signIn(_ command: String) {
        if let runCommand { runCommand(command) } else { AgentTerminalLauncher.open(command) }
    }

    // MARK: List

    public func numberOfRows(in tableView: NSTableView) -> Int { providers.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard providers.indices.contains(row) else { return nil }
        let provider = providers[row]
        let health = state?.health(provider.id)
        let cell = AgentProviderListCell()
        cell.configure(provider, logo: AgentLogo.image(for: provider, theme: theme),
                       detail: AgentProviderSummary.status(provider, health: health, run: state?.maintenance(provider.id)),
                       badge: AgentProviderSummary.badge(provider, health: health, run: state?.maintenance(provider.id)),
                       problem: provider.enabled && health?.status == .error)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard providers.indices.contains(row), providers[row].id != selectedID else { return }
        selectedID = providers[row].id
        variableName = ""; variableValue = ""; customModel = ""
        if let id = selectedID, models[id] == nil { loadModels(id, refresh: false) }
        rebuildDetail(force: true)
    }

    private func reloadList() {
        table.reloadData()
        if let index = providers.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        removeButton.isEnabled = selected != nil
        addButton.isEnabled = state != nil
        updateFooter()
    }

    private func updateFooter() {
        let interval = state?.settings.healthCheckInterval ?? AgentProviderSettings.defaultHealthCheckInterval
        if let index = Self.intervals.firstIndex(where: { $0.1 == interval }) {
            intervalPopUp.selectItem(at: index)
        } else {
            intervalPopUp.select(nil)
        }
        checkButton.isEnabled = !checking && !(providers.isEmpty)
        checkButton.title = checking ? "Checking…" : "Check Now"
        guard let latest = state?.health.map(\.checkedAt).max() else { checkedLabel.stringValue = "Not checked yet"; return }
        if Date().timeIntervalSince(latest) < 60 { checkedLabel.stringValue = "Checked just now"; return }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        checkedLabel.stringValue = "Checked \(formatter.localizedString(for: latest, relativeTo: Date()))"
    }

    // MARK: Detail

    /// Rebuilds the selected provider's page when what it shows changed. While a field is
    /// being edited it waits, so typing is never interrupted.
    func rebuildDetail(force: Bool = false) {
        let signature = detailSignature
        guard force || signature != shownSignature else { return }
        if !force, let editor = window?.firstResponder as? NSText, editor.isDescendant(of: detail) || (editor.delegate as? NSView)?.isDescendant(of: detail) == true {
            rebuildPending = true
            return
        }
        rebuildPending = false
        shownSignature = signature
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 14
        page.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 26, right: 26)
        if let error {
            page.addArrangedSubview(Self.note(error, color: .systemRed))
        }
        if state == nil {
            page.addArrangedSubview(Self.label(error == nil ? "Loading providers…" : "Providers unavailable", color: .secondaryLabelColor))
        } else if let provider = selected {
            buildProvider(provider, into: page)
        } else {
            buildEmpty(into: page)
        }
        detail.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            page.topAnchor.constraint(equalTo: detail.topAnchor),
            page.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        for view in page.arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -52).isActive = true }
    }

    private var detailSignature: String {
        guard let state else { return "loading|\(error ?? "")" }
        guard let provider = selected else { return "empty|\(error ?? "")|\(state.settings.providers.count)" }
        var parts = [String(describing: provider), String(describing: state.health(provider.id)),
                     String(describing: state.maintenance(provider.id)), String(describing: models[provider.id]),
                     "\(modelsUnavailable.contains(provider.id))", error ?? ""]
        parts.append(AgentProviderSummary.sharedAccountWarning(provider, state: state) ?? "")
        return parts.joined(separator: "|")
    }

    /// A field finished editing: a rebuild that waited for it runs now.
    func fieldDidEndEditing() {
        guard rebuildPending else { return }
        DispatchQueue.main.async { [weak self] in self?.rebuildDetail() }
    }

    private func buildEmpty(into page: NSStackView) {
        page.addArrangedSubview(Self.label("Add a coding agent", font: .systemFont(ofSize: 20, weight: .semibold)))
        page.addArrangedSubview(Self.wrapping("Connect Claude Code, Codex or another agent, with as many accounts as you need. "
            + "Conversations, the model menu and usage offer only the providers added here.", color: .secondaryLabelColor))
        let add = NSButton(title: "Add Provider…", target: self, action: #selector(addProvider))
        add.bezelStyle = .push
        add.keyEquivalent = "\r"
        page.addArrangedSubview(add)
    }

    private func buildProvider(_ provider: AgentProviderConfig, into page: NSStackView) {
        let id = provider.id
        let health = state?.health(id)
        let run = state?.maintenance(id)

        // Header: logo, title, what the last check found, and whether it is on.
        let logo = NSImageView(image: AgentLogo.image(for: provider, theme: theme) ?? NSImage())
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 36).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = Self.label(provider.title, font: .systemFont(ofSize: 20, weight: .semibold))
        let subtitle = Self.label(provider.enabled ? AgentProviderSummary.status(provider, health: health, run: run)
                                  : "Off. Conversations don't offer it, and its conversations can't start.", color: .secondaryLabelColor)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let enabled = AgentSettingsCheckbox(title: "Enabled", on: provider.enabled) { [weak self] on in
            self?.update(id) { $0.enabled = on }
        }
        let header = NSStackView(views: [logo, titles, NSView(), enabled])
        header.spacing = 12
        page.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -52).isActive = true

        if let state, let warning = AgentProviderSummary.sharedAccountWarning(provider, state: state) {
            page.addArrangedSubview(Self.note(warning, color: .systemOrange))
        }

        // Status: version with install or update, and sign-in.
        page.addArrangedSubview(Self.section("Status"))
        if provider.enabled, let health {
            let running = run?.isRunning == true
            var control: NSButton?
            let advisory = health.versionAdvisory
            if !health.installed {
                control = AgentSettingsButton(running ? "Installing…" : "Install", enabled: health.canInstall && !running) { [weak self] in
                    self?.maintain(id, .install)
                }
            } else if let advisory, advisory.status == .behindLatest || advisory.status == .unsupported {
                let title = advisory.latestVersion.map { "Update to \($0)" } ?? "Update"
                control = AgentSettingsButton(running ? "Updating…" : title, enabled: advisory.canUpdate && !running) { [weak self] in
                    self?.maintain(id, .update)
                }
            }
            page.addArrangedSubview(Self.row("Version", Self.wrapping(AgentProviderSummary.version(health)), control))
            if let message = health.message {
                page.addArrangedSubview(Self.note(message, color: health.status == .error ? .systemRed : .secondaryLabelColor))
            }
            var signIn: NSButton?
            if health.installed, health.auth != .signedIn, let command = health.signInCommand {
                signIn = AgentSettingsButton("Sign In…", enabled: true) { [weak self] in self?.signIn(command) }
                signIn?.toolTip = "Runs \(command) in a terminal"
            }
            page.addArrangedSubview(Self.row("Sign-in", Self.wrapping(AgentProviderSummary.signIn(provider, health: health)), signIn))
            if let run {
                page.addArrangedSubview(Self.note(AgentProviderSummary.maintenance(run), color: run.status == .failed ? .systemRed : .secondaryLabelColor))
                if let output = run.output, !run.isRunning, !output.isEmpty {
                    let text = Self.wrapping(output)
                    text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    text.textColor = .secondaryLabelColor
                    page.addArrangedSubview(text)
                }
            }
        } else {
            page.addArrangedSubview(Self.label(provider.enabled ? "Not checked yet" : "Off", color: .secondaryLabelColor))
        }

        // General.
        page.addArrangedSubview(Self.section("General"))
        page.addArrangedSubview(Self.row("Name", AgentSettingsField(provider.name ?? "", placeholder: provider.kind.name, owner: self) { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.update(id) { $0.name = name.isEmpty ? nil : name }
        }))
        let identifier = Self.label(id)
        identifier.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        identifier.isSelectable = true
        page.addArrangedSubview(Self.row("ID", identifier))
        page.addArrangedSubview(Self.row("Accent color", AgentAccentPopUp(selected: provider.accentColor) { [weak self] color in
            self?.update(id) { $0.accentColor = color }
        }))

        // How it runs.
        page.addArrangedSubview(Self.section("Command"))
        let spec = provider.kind.spec
        page.addArrangedSubview(Self.row("Executable", AgentSettingsField(provider.executable ?? "", placeholder: spec.executable ?? "e.g. qwen",
                                                                          monospaced: true, owner: self) { [weak self] text in
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.update(id) { $0.executable = path.isEmpty ? nil : path }
        }, description: spec.executable == nil ? "The agent to run: a command on PATH, or a full path. Required."
            : "Empty runs \(spec.executable ?? "") from PATH."))
        if let variable = provider.homeVariable {
            page.addArrangedSubview(Self.row(provider.supportsShadowHome ? "Codex folder" : "Config folder",
                                             AgentSettingsField(provider.home ?? "", placeholder: spec.defaultHome ?? "",
                                                                                monospaced: true, owner: self) { [weak self] text in
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.update(id) { $0.home = path.isEmpty ? nil : path }
            }, description: provider.supportsShadowHome ? "\(variable): the shared Codex folder, with its settings and conversations."
                : "\(variable): where it keeps its sign-in, settings and conversations. A folder of its own signs in to another account."))
        }
        if provider.supportsShadowHome {
            page.addArrangedSubview(Self.row("Account folder", AgentSettingsField(provider.shadowHome ?? "", placeholder: "e.g. ~/.codex-agentkit/personal",
                                                                                   monospaced: true, owner: self) { [weak self] text in
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.update(id) { $0.shadowHome = path.isEmpty ? nil : path }
            }, description: "Keeps this account's sign-in apart while sharing conversations and skills with the Codex folder."))
        }
        page.addArrangedSubview(Self.row("Arguments", AgentSettingsField(AgentCommandLine.line(provider.arguments), placeholder: spec.argumentsExample ?? "",
                                                                         monospaced: true, owner: self) { [weak self] text in
            do {
                let arguments = try AgentCommandLine.arguments(text)
                self?.update(id) { $0.arguments = arguments }
            } catch {
                self?.fail(error)
            }
        }, description: AgentProviderSummary.arguments(provider.kind)))
        if provider.kind == .claude {
            page.addArrangedSubview(Self.row("Auto-compact at", AgentSettingsField(provider.autoCompactTokens.map(String.init) ?? "",
                                                                                   placeholder: "e.g. 300000", owner: self) { [weak self] text in
                let digits = text.filter { !$0.isWhitespace && $0 != "," && $0 != "_" && $0 != "." }
                guard !digits.isEmpty else { self?.update(id) { $0.autoCompactTokens = nil }; return }
                guard let tokens = Int(digits), AgentProviderConfig.autoCompactRange.contains(tokens) else {
                    self?.error = "Enter a number of tokens from 100,000 to 1,000,000."
                    self?.rebuildDetail(force: true)
                    return
                }
                self?.update(id) { $0.autoCompactTokens = tokens }
            }, description: "The context size, in tokens, at which Claude compacts the conversation. Empty uses Claude's own."))
        }

        buildVariables(provider, into: page)
        buildModels(provider, into: page)

        let remove = AgentSettingsButton("Remove Provider…", enabled: true) { [weak self] in self?.confirmRemove(provider) }
        remove.hasDestructiveAction = true
        page.addArrangedSubview(Self.spacer(6))
        page.addArrangedSubview(remove)
    }

    private func buildVariables(_ provider: AgentProviderConfig, into page: NSStackView) {
        let id = provider.id
        page.addArrangedSubview(Self.section("Variables"))
        page.addArrangedSubview(Self.wrapping("Set for the CLI when it starts, such as API keys and base URLs.", color: .secondaryLabelColor))
        for (index, variable) in provider.environment.enumerated() {
            let value = AgentSettingsField(variable.value, placeholder: "Value", monospaced: true, owner: self) { [weak self] text in
                self?.update(id) { config in
                    guard config.environment.indices.contains(index) else { return }
                    config.environment[index].value = text
                }
            }
            let remove = AgentSettingsButton("Remove", enabled: true) { [weak self] in
                self?.update(id) { config in
                    guard config.environment.indices.contains(index) else { return }
                    config.environment.remove(at: index)
                }
            }
            remove.setAccessibilityLabel("Remove \(variable.name)")
            page.addArrangedSubview(Self.row(variable.name, value, remove, monospacedLabel: true))
        }
        let name = AgentSettingsField(variableName, placeholder: "NAME", monospaced: true, owner: self, live: true) { [weak self] in self?.variableName = $0 }
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        name.setAccessibilityLabel("Variable name")
        let value = AgentSettingsField(variableValue, placeholder: "Value", monospaced: true, owner: self, live: true) { [weak self] in self?.variableValue = $0 }
        value.setAccessibilityLabel("Variable value")
        let add = AgentSettingsButton("Add", enabled: true) { [weak self] in
            guard let self else { return }
            let name = variableName.trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                error = "A variable name has letters, digits and underscores, and doesn't start with a digit."
                rebuildDetail(force: true)
                return
            }
            let entry = AgentProviderVariable(name: name, value: variableValue)
            variableName = ""; variableValue = ""
            update(id) { config in
                if let existing = config.environment.firstIndex(where: { $0.name == name }) {
                    config.environment[existing] = entry
                } else {
                    config.environment.append(entry)
                }
            }
        }
        let row = NSStackView(views: [name, value, add])
        row.spacing = 8
        page.addArrangedSubview(Self.row("Add variable", row))
    }

    private func buildModels(_ provider: AgentProviderConfig, into page: NSStackView) {
        let id = provider.id
        page.addArrangedSubview(Self.section("Models"))
        let preferences = provider.models
        let hidden = Set(preferences.hidden), favorites = Set(preferences.favorites), custom = Set(preferences.custom.map(\.id))
        let list = models[id] ?? []
        let summary: String
        if management?.models == nil {
            summary = "This backend can't list models here."
        } else if let found = models[id] {
            let shown = found.filter { !hidden.contains($0.id) }.count
            summary = found.isEmpty ? "The CLI reported no models." : "\(shown) of \(found.count) shown in the model menu."
        } else {
            summary = modelsUnavailable.contains(id) ? "Couldn't list the models. Check that the CLI is installed and signed in." : "Loading models…"
        }
        let refresh = AgentSettingsButton("Refresh Models", enabled: management?.models != nil) { [weak self] in
            self?.models[id] = nil
            self?.rebuildDetail(force: true)
            self?.loadModels(id, refresh: true)
        }
        page.addArrangedSubview(Self.row("Model menu", Self.wrapping(summary, color: .secondaryLabelColor), refresh))

        func setModels(_ change: @escaping (inout AgentProviderModels) -> Void) {
            update(id) { change(&$0.models) }
            // The catalog's order follows the saved preferences; ask for it again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.loadModels(id, refresh: false) }
        }
        for (index, model) in list.enumerated() {
            let isFavorite = favorites.contains(model.id), isHidden = hidden.contains(model.id)
            // Favorites stay above the rest, so a model moves only among its own group.
            let canMoveUp = index > 0 && favorites.contains(list[index - 1].id) == isFavorite
            let canMoveDown = index + 1 < list.count && favorites.contains(list[index + 1].id) == isFavorite
            let star = AgentSettingsSymbolButton(isFavorite ? "star.fill" : "star",
                                                 label: isFavorite ? "Remove \(model.title) from favorites" : "Add \(model.title) to favorites") {
                setModels { models in
                    if isFavorite { models.favorites.removeAll { $0 == model.id } } else { models.favorites.append(model.id) }
                }
            }
            if isFavorite { star.contentTintColor = .systemYellow }
            let up = AgentSettingsSymbolButton("chevron.up", label: "Move \(model.title) up") {
                setModels { $0.order = Self.moving(list.map(\.id), from: index, to: index - 1) }
            }
            up.isEnabled = canMoveUp
            let down = AgentSettingsSymbolButton("chevron.down", label: "Move \(model.title) down") {
                setModels { $0.order = Self.moving(list.map(\.id), from: index, to: index + 1) }
            }
            down.isEnabled = canMoveDown
            let shown = AgentSettingsCheckbox(title: "Show", on: !isHidden) { on in
                setModels { models in
                    models.hidden.removeAll { $0 == model.id }
                    if !on { models.hidden.append(model.id) }
                }
            }
            shown.setAccessibilityLabel("Show \(model.title) in the model menu")
            var controls: [NSView] = [star, up, down, shown]
            if custom.contains(model.id) {
                let remove = AgentSettingsButton("Remove", enabled: true) {
                    setModels { models in
                        models.custom.removeAll { $0.id == model.id }
                        models.favorites.removeAll { $0 == model.id }
                        models.hidden.removeAll { $0 == model.id }
                        models.order.removeAll { $0 == model.id }
                    }
                }
                remove.setAccessibilityLabel("Remove \(model.title)")
                controls.append(remove)
            }
            let title = Self.label(model.title + (model.isDefault ? " (default)" : ""), font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium))
            let detailText = custom.contains(model.id) ? "\(model.id) · Added by you" : AgentProviderSummary.modelDetail(model)
            let titles = NSStackView(views: [title] + (detailText.map { [Self.label($0, color: .secondaryLabelColor, small: true)] } ?? []))
            titles.orientation = .vertical
            titles.alignment = .leading
            titles.spacing = 1
            let row = NSStackView(views: [titles, NSView()] + controls)
            row.spacing = 6
            page.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -52).isActive = true
        }

        let field = AgentSettingsField(customModel, placeholder: "Model ID", monospaced: true, owner: self, live: true) { [weak self] in self?.customModel = $0 }
        field.setAccessibilityLabel("Model ID to add")
        let add = AgentSettingsButton("Add", enabled: true) { [weak self] in
            guard let self else { return }
            let modelID = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else { return }
            guard !list.contains(where: { $0.id == modelID }) else {
                error = "\(modelID) is already listed."
                rebuildDetail(force: true)
                return
            }
            customModel = ""
            setModels { $0.custom.append(AgentCustomModel(id: modelID)) }
        }
        let row = NSStackView(views: [field, add])
        row.spacing = 8
        page.addArrangedSubview(Self.row("Add a model", row, description: "For one the CLI doesn't report yet, such as a new release."))
    }

    static func moving(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from), ids.indices.contains(to) else { return ids }
        var ids = ids
        ids.swapAt(from, to)
        return ids
    }

    // MARK: Building blocks

    static func label(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor,
                      small: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = small ? .systemFont(ofSize: NSFont.smallSystemFontSize) : font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func wrapping(_ text: String, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = color
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 460
        return label
    }

    static func note(_ text: String, color: NSColor) -> NSTextField {
        let label = wrapping(text, color: color)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    static func section(_ title: String) -> NSView {
        let label = Self.label(title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        let stack = NSStackView(views: [spacer(4), label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    static func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// A label column, a control and an optional trailing button, with an optional line under the control.
    static func row(_ title: String, _ control: NSView, _ trailing: NSView? = nil, description: String? = nil,
                    monospacedLabel: Bool = false) -> NSView {
        let label = Self.label(title, color: .secondaryLabelColor)
        if monospacedLabel { label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        var column: [NSView] = [control]
        if let description { column.append(note(description, color: .secondaryLabelColor)) }
        let right = NSStackView(views: column)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 4
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if control is NSTextField, (control as? NSTextField)?.isEditable == true {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }
        let row = NSStackView(views: [label, right] + (trailing.map { [$0] } ?? []))
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }
}

/// The settings page's document view, laid out from the top.
final class AgentSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A provider in the settings list: its logo, name, status line and a badge when it needs attention.
@MainActor
final class AgentProviderListCell: NSTableCellView {
    private let logo = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titles = NSStackView(views: [title, detail])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [logo, titles, NSView(), badge])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 22), logo.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ provider: AgentProviderConfig, logo image: NSImage?, detail text: String, badge word: String?, problem: Bool) {
        logo.image = image
        logo.alphaValue = provider.enabled ? 1 : 0.45
        title.stringValue = provider.title
        detail.stringValue = text
        badge.stringValue = word ?? ""
        badge.isHidden = word == nil
        badge.textColor = problem ? .systemRed : .secondaryLabelColor
        setAccessibilityLabel([provider.title, word, text].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A text field that saves when editing ends, or on every keystroke when `live`.
@MainActor
final class AgentSettingsField: NSTextField, NSTextFieldDelegate {
    private let commit: (String) -> Void
    private let live: Bool
    private weak var owner: AgentSettingsWindowController?
    private var original: String

    init(_ value: String, placeholder: String, monospaced: Bool = false, owner: AgentSettingsWindowController?, live: Bool = false,
         commit: @escaping (String) -> Void) {
        self.commit = commit
        self.live = live
        self.owner = owner
        original = value
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        isEditable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ obj: Notification) {
        if live { commit(stringValue) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if !live, stringValue != original {
            original = stringValue
            commit(stringValue)
        }
        owner?.fieldDidEndEditing()
    }
}

/// A push button running a closure.
@MainActor
final class AgentSettingsButton: NSButton {
    private let run: () -> Void

    init(_ title: String, enabled: Bool, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        isEnabled = enabled
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press() { run() }
}

/// A borderless SF Symbol button running a closure.
@MainActor
final class AgentSettingsSymbolButton: NSButton {
    private let run: () -> Void

    init(_ symbol: String, label: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press() { run() }
}

/// A checkbox running a closure with its new state.
@MainActor
final class AgentSettingsCheckbox: NSButton {
    private let run: (Bool) -> Void

    init(title: String, on: Bool, run: @escaping (Bool) -> Void) {
        self.run = run
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = on ? .on : .off
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggle() { run(state == .on) }
}

/// The accent colors a provider may take, with None.
@MainActor
final class AgentAccentPopUp: NSPopUpButton {
    private let run: (String?) -> Void
    private static let names = ["#F2701B": "Orange", "#E5484D": "Red", "#D6409F": "Pink", "#8E4BF2": "Purple",
                                "#1F6FEB": "Blue", "#1E9AA0": "Teal", "#2FA84A": "Green", "#F29D1B": "Amber"]

    init(selected: String?, run: @escaping (String?) -> Void) {
        self.run = run
        super.init(frame: .zero, pullsDown: false)
        addItem(withTitle: "None")
        for hex in AgentProviderConfig.accentColors {
            addItem(withTitle: Self.names[hex] ?? hex)
            lastItem?.representedObject = hex
            lastItem?.image = Self.swatch(hex)
        }
        if let selected, !AgentProviderConfig.accentColors.contains(selected.uppercased()) {
            addItem(withTitle: selected)
            lastItem?.representedObject = selected
            lastItem?.image = Self.swatch(selected)
        }
        select(itemArray.first { ($0.representedObject as? String)?.uppercased() == selected?.uppercased() } ?? itemArray.first)
        target = self
        action = #selector(changed)
        setAccessibilityLabel("Accent color")
    }

    required init?(coder: NSCoder) { nil }

    static func swatch(_ hex: String) -> NSImage? {
        guard let color = RGBColor(hex: hex)?.nsColor else { return nil }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func changed() { run(selectedItem?.representedObject as? String) }
}

/// Runs a command in Terminal, for hosts without a terminal of their own.
enum AgentTerminalLauncher {
    @MainActor
    static func open(_ command: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentKit-\(UUID().uuidString)", isDirectory: true)
        let script = folder.appendingPathComponent("Sign In.command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "#!/bin/zsh -l\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Run this in Terminal to sign in"
            alert.informativeText = "\(command)\n\nThe command was copied."
            alert.runModal()
        }
    }
}
