import AgentCore
import XCTest

final class AgentProviderDraftTests: XCTestCase {
    func testAnotherAccountOfAKindGetsAFolderOfItsOwn() throws {
        let empty = AgentProviderSettings()
        let firstClaude = AgentProviderDraft(kind: .claude, settings: empty)
        XCTAssertEqual(firstClaude.id, "claude")
        XCTAssertEqual(firstClaude.home, "", "the first Claude uses its default config folder")

        let settings = AgentProviderSettings(providers: [.builtIn(.claude), .builtIn(.codex)])
        var first = AgentProviderDraft(kind: .acp, settings: settings)
        XCTAssertEqual(first.id, "acp")
        XCTAssertEqual(first.configError(), "Enter the agent's command.")
        first.executable = "qwen"
        first.arguments = "--acp"
        XCTAssertEqual(first.config.arguments, ["--acp"])
        first.arguments = "--acp 'unclosed"
        XCTAssertEqual(first.configError(), "Close the quote in the launch arguments.")

        var claude = AgentProviderDraft(kind: .claude, settings: settings)
        XCTAssertEqual(claude.home, "~/.claude-2", "a second Claude signs in to its own folder")
        claude.setLabel("Work", settings: settings)
        XCTAssertEqual(claude.id, "claude-work")
        XCTAssertEqual(claude.home, "~/.claude-work", "the folder follows the label until edited")
        claude.accentColor = "#8E4BF2"
        claude.useAPIKey = true
        XCTAssertEqual(claude.configError(), "Enter the API key.")
        claude.apiKey = "sk-test"
        let config = claude.config
        XCTAssertEqual(config.name, "Work")
        XCTAssertEqual(config.home, "~/.claude-work")
        XCTAssertEqual(config.environment, [AgentProviderVariable(name: "ANTHROPIC_API_KEY", value: "sk-test")])
        XCTAssertEqual(config.accentColor, "#8E4BF2")
        XCTAssertNoThrow(try config.validate())

        var codex = AgentProviderDraft(kind: .codex, settings: settings)
        codex.setLabel("Personal", settings: settings)
        XCTAssertEqual(codex.shadowHome, "~/.codex-agentkit/personal", "a second Codex shares the Codex folder but not its sign-in")
        XCTAssertEqual(codex.home, "")
        codex.id = "codex"
        codex.idEdited = true
        XCTAssertEqual(codex.identityError(settings), "Another provider has the ID “codex”.")
    }

    func testASecondAccountMustBeToldApartAndIsWarnedWhenItWouldShareASignIn() {
        let settings = AgentProviderSettings(providers: [.builtIn(.claude)])
        var work = AgentProviderDraft(kind: .claude, settings: settings)
        XCTAssertEqual(work.accentColor, AgentProviderConfig.accentColors.first, "another account starts with a color of its own")
        XCTAssertEqual(work.identityError(settings), "Enter a label, such as Work or Personal, to tell it apart from “Claude Code”.")
        work.setLabel("claude code", settings: settings)
        XCTAssertEqual(work.identityError(settings), "Another Claude Code provider is called “claude code”.")
        work.setLabel("Work", settings: settings)
        XCTAssertNil(work.identityError(settings))
        XCTAssertNil(work.sharedSignIn(settings), "its own folder is its own sign-in")
        let state = AgentProvidersState(settings: settings, health: [
            AgentProviderHealth(provider: "claude", installed: true, auth: .signedIn, email: "me@example.com", checkedAt: Date()),
        ])
        let sameEmail = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.323", auth: .signedIn,
                                            email: "Me@Example.com", checkedAt: Date())
        XCTAssertEqual(work.warning(health: sameEmail, state: state), "Signed in as me@example.com, the same account as “Claude Code”.")

        work.home = "~/.claude"
        XCTAssertEqual(work.sharedSignIn(settings)?.id, "claude")
        XCTAssertEqual(work.warning(health: nil, state: state),
                       "“Claude Code” already signs in from ~/.claude, so both would be one account. Choose another folder to add a different account.")

        // Antigravity keeps one Google sign-in per computer, so another account starts on an API key.
        let agy = AgentProviderSettings(providers: [.builtIn(.antigravity)])
        var second = AgentProviderDraft(kind: .antigravity, settings: agy)
        XCTAssertTrue(second.useAPIKey)
        second.useAPIKey = false
        XCTAssertEqual(second.sharedSignIn(agy)?.id, "antigravity")

        let gemini = AgentProviderDraft(kind: .gemini, settings: AgentProviderSettings(providers: [.builtIn(.gemini)]))
        XCTAssertEqual(gemini.home, "~/.gemini-2", "another Gemini CLI account gets a home folder of its own")
        XCTAssertNil(gemini.sharedSignIn(AgentProviderSettings(providers: [.builtIn(.gemini)])))
    }

    func testTheFormSaysWhatItFoundOfTheCLI() {
        let draft = AgentProviderDraft(kind: .claude, settings: AgentProviderSettings())
        XCTAssertEqual(draft.status(health: nil, checking: true).text, "Checking Claude Code…")
        let signedIn = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.323", auth: .signedIn,
                                           account: "Claude Team subscription", email: "me@example.com", checkedAt: Date())
        XCTAssertEqual(draft.status(health: signedIn, checking: false).text,
                       "Claude Code 2.1.323 · Signed in as me@example.com · Claude Team subscription")
        let missing = AgentProviderHealth(provider: "claude", installed: false, checkedAt: Date(), installCommand: "brew install claude")
        let status = draft.status(health: missing, checking: false)
        XCTAssertTrue(status.problem)
        XCTAssertTrue(status.text.hasPrefix("Claude Code isn't installed."))
    }

    func testNewIDDoesNotDuplicateTheProviderKindPrefix() {
        let withEnterprise = AgentProviderSettings(providers: [
            AgentProviderConfig(id: "claude-enterprise", kind: .claude, name: "Enterprise"),
        ])
        XCTAssertEqual(withEnterprise.newID(.claude, label: "Claude Personal"), "claude-personal")
        XCTAssertEqual(withEnterprise.newID(.claude, label: "Claude Code Personal"), "claude-personal")
        XCTAssertEqual(withEnterprise.newID(.claude, label: "Claude"), "claude")

        var draft = AgentProviderDraft(kind: .claude, settings: withEnterprise)
        draft.setLabel("Claude Personal", settings: withEnterprise)
        XCTAssertEqual(draft.id, "claude-personal")
        XCTAssertEqual(draft.home, "~/.claude-personal", "folder does not double the claude prefix")
    }

    func testLaunchArgumentsReadBackAsTyped() throws {
        let arguments = ["--chrome", "--name", "two words", "it's"]
        XCTAssertEqual(try AgentCommandLine.arguments(AgentCommandLine.line(arguments)), arguments)
        XCTAssertEqual(try AgentCommandLine.arguments(""), [])
        XCTAssertEqual(try AgentCommandLine.arguments(#"--flag "a \"quoted\" word""#), ["--flag", #"a "quoted" word"#])
        XCTAssertThrowsError(try AgentCommandLine.arguments("--x \\"))
    }

    func testTheSummaryNamesWhatNeedsAttention() {
        let claude = AgentProviderConfig.builtIn(.claude)
        let behind = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.1", auth: .signedIn, checkedAt: Date(),
                                         versionAdvisory: .init(status: .behindLatest, latestVersion: "2.1.9", canUpdate: true))
        XCTAssertEqual(AgentProviderSummary.badge(claude, health: behind, run: nil), "Update")
        XCTAssertEqual(AgentProviderSummary.status(claude, health: behind), "2.1.1 · Signed in · 2.1.9 available")
        var off = claude
        off.enabled = false
        XCTAssertEqual(AgentProviderSummary.badge(off, health: behind, run: nil), "Off")
        XCTAssertEqual(AgentProviderSummary.modelDetail(.init(id: "opus[1m]", title: "Opus", reasoningEfforts: [], resolvedModel: "claude-opus-5-5")),
                       "claude-opus-5-5 · 1M context")
    }
}
