import Foundation

/// What agent settings need from a backend to add, configure, check, install and update its
/// providers and arrange their models. `AgentWorkspace` supplies one from its
/// `AgentProviderStore`; a host with its own transport supplies its own closures.
public struct AgentProviderManagement: Sendable {
    /// The providers and their last checks, starting a check of any that are due.
    public var state: @Sendable () async throws -> AgentProvidersState
    /// Checks every enabled provider's CLI, version and sign-in now.
    public var check: @Sendable () async throws -> AgentProvidersState
    /// Saves the providers, replacing the backend's list.
    public var write: @Sendable (AgentProviderSettings) async throws -> AgentProvidersState
    /// Installs or updates a provider's CLI; the state reports the run as it goes.
    public var maintain: @Sendable (String, AgentProviderMaintenance.Action) async throws -> AgentProvidersState
    /// Checks a provider as it would run, saved or not, changing nothing: the Add Provider
    /// form's view of what it is filling in. Nil when the backend can't.
    public var probe: (@Sendable (AgentProviderConfig) async -> AgentProviderHealth?)?
    /// Every model a saved provider reports, hidden ones included, in the menu's order;
    /// `true` asks the CLI again instead of using what it last said.
    public var models: (@Sendable (AgentProviderConfig, Bool) async throws -> [AgentModelDescriptor])?

    public init(state: @escaping @Sendable () async throws -> AgentProvidersState,
                check: @escaping @Sendable () async throws -> AgentProvidersState,
                write: @escaping @Sendable (AgentProviderSettings) async throws -> AgentProvidersState,
                maintain: @escaping @Sendable (String, AgentProviderMaintenance.Action) async throws -> AgentProvidersState,
                probe: (@Sendable (AgentProviderConfig) async -> AgentProviderHealth?)? = nil,
                models: (@Sendable (AgentProviderConfig, Bool) async throws -> [AgentModelDescriptor])? = nil) {
        self.state = state
        self.check = check
        self.write = write
        self.maintain = maintain
        self.probe = probe
        self.models = models
    }
}

/// Command lines as agent settings show and read them: launch arguments in one field.
public enum AgentCommandLine {
    public struct Failure: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Splits `source` the way a POSIX shell splits words, with single and double quotes
    /// and backslash escapes, without running anything. Empty text has no words.
    public static func arguments(_ source: String) throws -> [String] {
        if source.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw Failure(message: "Arguments must not contain control characters.")
        }
        var arguments: [String] = []
        var word = ""
        var started = false
        var quote: Character?
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            switch (quote, character) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case (nil, "'"), (nil, "\""):
                quote = character
                started = true
            case (nil, "\\"), ("\"", "\\"):
                guard let escaped = iterator.next() else {
                    throw Failure(message: "Arguments must not end with an unescaped backslash.")
                }
                if quote == "\"" && !["\"", "\\", "$", "`"].contains(escaped) { word.append("\\") }
                word.append(escaped)
                started = true
            case (nil, _) where character.isWhitespace:
                if started {
                    arguments.append(word)
                    word = ""
                    started = false
                }
            default:
                word.append(character)
                started = true
            }
        }
        if quote != nil { throw Failure(message: "Close the quote in the launch arguments.") }
        if started { arguments.append(word) }
        return arguments
    }

    /// `arguments` as one line that `arguments(_:)` reads back, single-quoting the ones a
    /// shell would split or expand.
    public static func line(_ arguments: [String]) -> String {
        arguments.map { argument in
            let plain = !argument.isEmpty && argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }
            return plain ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

/// The Add Provider form as its fields hold it. Another provider of a kind gets what keeps
/// it a separate account: a config folder of its own, or an API key for a kind that keeps
/// one sign-in per computer, and an accent color of its own.
public struct AgentProviderDraft: Equatable, Sendable {
    public var kind: AgentChatProvider
    public var label = ""
    public var id = ""
    /// Whether the ID was typed rather than derived from the label.
    public var idEdited = false
    public var accentColor: String?
    public var executable = ""
    public var home = ""
    public var shadowHome = ""
    public var arguments = ""
    public var useAPIKey = false
    public var apiKeyVariable = ""
    public var apiKey = ""

    public init(kind: AgentChatProvider, settings: AgentProviderSettings) {
        self.kind = kind
        reset(kind, settings: settings)
    }

    private init(empty kind: AgentChatProvider) { self.kind = kind }

    /// Starts over for `kind`, with its derived ID and what keeps it apart from providers
    /// of the kind already added.
    public mutating func reset(_ kind: AgentChatProvider, settings: AgentProviderSettings) {
        self = AgentProviderDraft(empty: kind)
        id = settings.newID(kind, label: label)
        apiKeyVariable = kind.spec.apiKeyVariables.first ?? ""
        let others = settings.providers.filter { $0.kind == kind }
        guard !others.isEmpty, kind != .acp else { return }
        let taken = Set(others.compactMap { $0.accentColor?.uppercased() })
        accentColor = AgentProviderConfig.accentColors.first { !taken.contains($0) }
        if kind.spec.homeVariable == nil {
            useAPIKey = !kind.spec.apiKeyVariables.isEmpty
            return
        }
        let folder = suffix(id).isEmpty ? "2" : suffix(id)
        if kind == .codex {
            shadowHome = "~/.codex-agentkit/\(folder)"
        } else if let home = kind.spec.defaultHome {
            // Gemini CLI's variable stands for the home folder it keeps `.gemini` in.
            self.home = home == "~" ? "~/.\(kind.rawValue)-\(folder)" : "\(home)-\(folder)"
        }
    }

    private func suffix(_ id: String) -> String {
        String(id.dropFirst(kind.rawValue.count).drop { $0 == "-" })
    }

    /// Follows a new label with the ID, and the folders while they still follow the ID.
    public mutating func setLabel(_ text: String, settings: AgentProviderSettings) {
        label = text
        guard !idEdited else { return }
        let old = id
        id = settings.newID(kind, label: text)
        let oldSuffix = suffix(old), newSuffix = suffix(id)
        guard !oldSuffix.isEmpty || !newSuffix.isEmpty else { return }
        let from = oldSuffix.isEmpty ? "2" : oldSuffix, to = newSuffix.isEmpty ? "2" : newSuffix
        if shadowHome.hasSuffix("/\(from)") { shadowHome = String(shadowHome.dropLast(from.count)) + to }
        if home.hasSuffix("-\(from)") { home = String(home.dropLast(from.count)) + to }
    }

    /// The providers of the same kind already added.
    public func siblings(_ settings: AgentProviderSettings) -> [AgentProviderConfig] {
        settings.providers.filter { $0.kind == kind }
    }

    /// Why the label or ID can't be used, or nil.
    public func identityError(_ settings: AgentProviderSettings) -> String? {
        let id = id.trimmingCharacters(in: .whitespaces)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = siblings(settings)
        if let first = others.first, label.isEmpty {
            return "Enter a label, such as Work or Personal, to tell it apart from “\(first.title)”."
        }
        let title = label.isEmpty ? kind.name : label
        if others.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return "Another \(kind.name) provider is called “\(title)”."
        }
        guard !id.isEmpty else { return "Enter an ID." }
        guard AgentProviderConfig.isValidID(id) else { return "An ID has up to 64 letters, digits, “-” and “_”." }
        guard settings.provider(id) == nil else { return "Another provider has the ID “\(id)”." }
        return nil
    }

    /// Why the way it runs can't be used, or nil.
    public func configError() -> String? {
        if kind.spec.executable == nil, executable.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the agent's command."
        }
        do { _ = try AgentCommandLine.arguments(arguments) } catch { return error.localizedDescription }
        if useAPIKey, apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the API key." }
        return nil
    }

    /// The provider already added that this one would share a sign-in with, making it the same account.
    public func sharedSignIn(_ settings: AgentProviderSettings) -> AgentProviderConfig? {
        let config = config
        return settings.providers.first { config.sharesSignIn(with: $0) }
    }

    public var config: AgentProviderConfig {
        func trimmed(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let key = useAPIKey ? trimmed(apiKey) : nil
        return AgentProviderConfig(
            id: id.trimmingCharacters(in: .whitespaces), kind: kind, name: trimmed(label),
            executable: trimmed(executable), home: kind.spec.homeVariable == nil ? nil : trimmed(home),
            shadowHome: kind == .codex ? trimmed(shadowHome) : nil, accentColor: accentColor,
            arguments: (try? AgentCommandLine.arguments(arguments)) ?? [],
            environment: key.map { [AgentProviderVariable(name: apiKeyVariable, value: $0)] } ?? [])
    }

    /// Why the form may not be the separate account it is meant to be, or nil.
    public func warning(health: AgentProviderHealth?, state: AgentProvidersState) -> String? {
        if let other = sharedSignIn(state.settings) {
            if useAPIKey { return "“\(other.title)” uses the same API key, so both are one account." }
            guard let folder = config.signInFolder else {
                return "\(kind.name) keeps one account sign-in per computer, so this is the same account as “\(other.title)”. "
                    + "Choose API key to add another account."
            }
            return "“\(other.title)” already signs in from \(folder), so both would be one account. "
                + "Choose another folder to add a different account."
        }
        guard let email = health?.email?.lowercased(), health?.auth == .signedIn else { return nil }
        let same = siblings(state.settings).first { state.health($0.id)?.email?.lowercased() == email }
        return same.map { "Signed in as \(email), the same account as “\($0.title)”." }
    }

    /// What a check of the form found of the CLI and its sign-in, and whether that is a problem.
    public func status(health: AgentProviderHealth?, checking: Bool) -> (text: String, problem: Bool) {
        let name = kind.name
        guard let health else { return (checking ? "Checking \(name)…" : "", false) }
        guard health.installed else {
            let install = health.installCommand.map { " Install it with `\($0)`, or add it now and install it from its page." } ?? ""
            return ("\(name) isn't installed.\(install)", true)
        }
        let version = health.version.map { "\(name) \($0)" } ?? name
        if let advisory = health.versionAdvisory, advisory.status == .unsupported, let minimum = advisory.minimumVersion {
            return ("\(version) is older than \(minimum), the oldest AgentKit works with. Update it from its page once it is added.", true)
        }
        switch health.auth {
        case .signedIn:
            let who = [health.email.map { "as \($0)" }, health.account].compactMap { $0 }.joined(separator: " · ")
            return ("\(version) · Signed in\(who.isEmpty ? "" : " " + who)", false)
        case .signedOut where useAPIKey:
            return ("\(version) · Signs in with the API key.", false)
        case .signedOut:
            return ("\(version) · Not signed in here yet. Once it is added, sign in from its page.", false)
        case .unknown:
            return ("\(version) · AgentKit can't tell whether it is signed in.", false)
        }
    }
}

/// How agent settings describe a provider and what its last check found.
public enum AgentProviderSummary {
    /// A word beside a provider in the list when it needs attention.
    public static func badge(_ provider: AgentProviderConfig, health: AgentProviderHealth?, run: AgentProviderMaintenance?) -> String? {
        guard provider.enabled else { return "Off" }
        if run?.isRunning == true { return run?.action == .install ? "Installing" : "Updating" }
        guard let health else { return nil }
        if !health.installed { return "Not installed" }
        if health.versionAdvisory?.status == .unsupported { return "Too old" }
        if health.auth == .signedOut { return "Signed out" }
        if health.versionAdvisory?.status == .behindLatest { return "Update" }
        return nil
    }

    /// One line under a provider in the list.
    public static func status(_ provider: AgentProviderConfig, health: AgentProviderHealth?,
                              run: AgentProviderMaintenance? = nil) -> String {
        guard provider.enabled else { return "Off" }
        if let run, run.isRunning { return maintenance(run) }
        guard let health else { return "Not checked yet" }
        guard health.installed else { return "Not found" }
        var parts: [String]
        switch health.auth {
        case .signedIn: parts = [health.email.map { "Signed in as \($0)" } ?? "Signed in", health.account].compactMap { $0 }
        case .signedOut: parts = ["Not signed in"]
        case .unknown: parts = ["Installed"]
        }
        if let version = health.version { parts.insert(version, at: 0) }
        if let advisory = health.versionAdvisory {
            if advisory.status == .behindLatest, let latest = advisory.latestVersion { parts.append("\(latest) available") }
            if advisory.status == .unsupported, let minimum = advisory.minimumVersion { parts.append("needs \(minimum)") }
        }
        return parts.joined(separator: " · ")
    }

    /// The version line: installed, latest and oldest supported, and how it updates.
    public static func version(_ health: AgentProviderHealth) -> String {
        guard health.installed else {
            return health.installCommand.map { "Not installed. Install it with `\($0)`." } ?? "Not installed."
        }
        var parts = [health.version.map { "Version \($0)" } ?? "Version unknown"]
        if let advisory = health.versionAdvisory {
            switch advisory.status {
            case .current: parts.append("Up to date")
            case .behindLatest: parts.append(advisory.latestVersion.map { "\($0) is available" } ?? "An update is available")
            case .unsupported: parts.append(advisory.minimumVersion.map { "AgentKit needs \($0) or later" } ?? "Too old for AgentKit")
            case .unknown: break
            }
            if let installedBy = advisory.installedBy { parts.append("Installed with \(installedBy)") }
            if !advisory.canUpdate, advisory.status != .current, let command = advisory.updateCommand {
                parts.append("Update it with `\(command)`")
            }
        }
        if let path = health.executablePath { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    /// What an install or update is doing, or how it ended.
    public static func maintenance(_ run: AgentProviderMaintenance) -> String {
        let doing = run.action == .install ? "Installing" : "Updating"
        switch run.status {
        case .running: return "\(doing)… \(run.message ?? run.command)"
        case .succeeded, .unchanged, .failed: return run.message ?? "\(run.command) finished."
        }
    }

    /// How it is signed in, in a line.
    public static func signIn(_ provider: AgentProviderConfig, health: AgentProviderHealth) -> String {
        guard health.installed else { return "Install \(provider.kind.name) first." }
        switch health.auth {
        case .signedIn:
            let who = [health.email, health.account].compactMap { $0 }.joined(separator: " · ")
            return who.isEmpty ? "Signed in" : "Signed in · \(who)"
        case .signedOut:
            return health.signInCommand.map { "Not signed in. Sign in with `\($0)`." } ?? "Not signed in."
        case .unknown:
            switch provider.kind {
            case .acp: return "AgentKit can't tell whether this agent is signed in. A conversation says so when it isn't."
            case .openCode: return "OpenCode has no saved model provider credentials, so only its free models may work. Run `opencode auth login` to add one."
            default: return "AgentKit couldn't tell whether \(provider.title) is signed in."
            }
        }
    }

    /// What the launch arguments are added to.
    public static func arguments(_ kind: AgentChatProvider) -> String {
        switch kind.spec.wire {
        case .claudeStream: "Added to Claude Code's command line when a conversation starts."
        case .codexAppServer: "Added after codex app-server when a conversation starts."
        case .acp where kind == .acp: "The arguments that start the agent's Agent Client Protocol server, such as --acp."
        case .acp: "Added after \(([kind.spec.executable ?? ""] + kind.spec.sessionArguments).joined(separator: " ")) when a conversation starts."
        }
    }

    /// The real model ID under a model: aliases like "opus" say nothing, and a "[1m]" suffix
    /// means the 1M-token context variant. Nil when it would repeat the title.
    public static func modelDetail(_ model: AgentModelDescriptor) -> String? {
        var id = model.id
        var notes: [String] = []
        if id.hasSuffix("[1m]") {
            id.removeLast(4)
            notes.append("1M context")
        }
        if let resolved = model.resolvedModel, !resolved.isEmpty { id = resolved }
        let detail = ([id] + notes).joined(separator: " · ")
        return detail == model.title ? nil : detail
    }

    /// Why `provider` is the same account as another one, or nil: they sign in from the same
    /// place, or their checks found the same signed-in address.
    public static func sharedAccountWarning(_ provider: AgentProviderConfig, state: AgentProvidersState) -> String? {
        let others = state.settings.providers.filter { $0.id != provider.id && $0.kind == provider.kind }
        if let other = others.first(where: provider.sharesSignIn) {
            if provider.apiKey != nil { return "“\(other.title)” uses the same API key, so both are one account." }
            guard let folder = provider.signInFolder else {
                return "\(provider.kind.name) keeps one account sign-in per computer, so this is the same account as “\(other.title)”. "
                    + "Add an API key under Variables to use another account."
            }
            return "“\(other.title)” also signs in from \(folder), so both are one account. "
                + "Set a folder of its own, then sign in, to use another account."
        }
        guard let health = state.health(provider.id), health.auth == .signedIn, let email = health.email?.lowercased(),
              let other = others.first(where: { state.health($0.id)?.auth == .signedIn && state.health($0.id)?.email?.lowercased() == email })
        else { return nil }
        return "Signed in as \(email), the same account as “\(other.title)”. Sign in to another account to tell them apart."
    }
}
