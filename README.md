# AgentKit

Embed a native AI conversation in your macOS app, backed by a locally installed
Claude Code or Codex CLI. AgentKit includes the conversation UI, provider runtime,
application tool calls, and persistent session management extracted from [Tab](https://github.com/hugocxl/tab).

One Swift package, three modules:

| Module | Use it for |
| --- | --- |
| `AgentCore` | Conversation models, commands, attachments, and the transport interface. |
| `AgentRuntime` | Running local CLI providers and persisting conversations. No AppKit dependency. |
| `AgentUI` | The native AppKit transcript and composer, with an optional SwiftUI wrapper. No runtime dependency. |

Requires macOS 14 or later on Apple silicon. Build with Xcode 26 or later and Swift
6; the package uses Swift 5 language mode. The runtime launches installed provider
executables. Install and sign in to the provider CLI before using a real conversation.
AgentKit does not bundle a model or manage provider accounts.

## Install

Add `https://github.com/hugocxl/agentkit.git` in Xcode's package dependencies, or add:

```swift
.package(url: "https://github.com/hugocxl/agentkit.git", from: "1.1.0")
```

Select the products your target needs:

```swift
.product(name: "AgentCore", package: "agentkit"),
.product(name: "AgentRuntime", package: "agentkit"),
.product(name: "AgentUI", package: "agentkit"),
```

The repository is private; consumers need GitHub access. IconsCXL is the package's
only external Swift dependency. Rendering uses AppKit rather than a web transcript.

## Build an AI-first app

Your app provides its domain tools and their handlers. AgentKit supplies the native
conversation, streaming, local CLI connection, model selection, tool results, and
session lifecycle. The same tool definitions work with both providers.

```swift
import AgentCore
import AgentRuntime
import AgentUI

let tools = AgentToolConfiguration([
    AgentToolDefinition(
        name: "add_title",
        description: "Add a title to the current video project.",
        inputSchema: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"]
        ]
    )
]) { @MainActor call in
    guard !Task.isCancelled, let text = call.arguments["text"]?.string else {
        return .failure("A title is required.")
    }
    editor.addTitle(text) // Your app's normal editing and undo path.
    return AgentToolResult(text: "Added the title.")
}

// Persist this ID with the workspace; reuse it on subsequent launches.
let workspace = try AgentWorkspace(
    workingDirectory: projectDirectory,
    storageDirectory: applicationSupport.appendingPathComponent("my-workspace"),
    project: savedProjectID,
    instructions: "Help edit this video using the application's tools.",
    tools: tools
)

// Retain both objects. Persist the session ID to reopen the conversation.
let connection = workspace.connect(provider: .codex, session: savedSessionID)
let conversation = AgentConversationViewController(connection: connection)
```

Create UI objects on the main actor. Initialize a workspace off the main actor when
loading persisted state. Creating a connection does not start a turn; the first
submitted prompt starts the CLI. Use `.claude` to use Claude Code.

Embed the controller directly in AppKit or retain it in your SwiftUI model and use:

```swift
AgentConversationView(controller: conversation)
```

Application tools default to `.applicationOnly` access: Claude's built-in tools are
disabled; Codex runs read-only with shell execution disabled and no approvals. The
host remains responsible for validating arguments, authorizing operations, and
committing undoable edits. Handlers run in order per conversation and should honor
cancellation before committing changes. AgentKit deduplicates retried call IDs,
displays results, and returns `AgentToolResult.images` to both the model and UI.

Application mode omits coding-specific commands, plan mode, provider-history import,
and file-checkpoint rollback. Use your app's own undo tool. For a coding workspace,
omit `tools`; to combine application and provider tools explicitly, pass
`access: .providerTools` to `AgentToolConfiguration`.

`executables`, `environment`, and `instructions` customize provider launches. Use a
dedicated storage directory for each workspace; an ownership record and exclusive
lock prevent accidental reuse or simultaneous writers. The working directory and
storage directory are independent.

[Filmatte](https://github.com/hugocxl/filmatte) is the first local consumer: its tool
catalog and editor handlers remain in the app, while AgentKit supplies the UI and
both CLI transports. The integration tests exercise real text-overlay and timeline
edits through each installed provider.

## What the conversation includes

- Streaming replies, native Markdown, syntax-highlighted code, tables, math, and diagrams.
- An editable composer with attachments, model and reasoning selection, and plan mode.
- Tool activity, approvals, structured questions, prompt queues, and interruption.
- Search, prompt navigation, context usage, citations, and subagent activity.
- Persistent transcripts and drafts, provider-history import, and supported conversation forks.
- Recorded file changes, Git checkpoints, diff review, and guarded revert operations.
- Local file and media previews, including revision-checked ranged reads.

Provider features vary. The adapters retain each provider's behavior rather than
simulating unsupported operations. `AgentConnection.capabilities` controls optional UI features. Host-specific actions such as opening another
conversation, launching a terminal, or previewing a pull request require host services.

## Integrate your app

Pass `AgentHostServices` when constructing the controller to connect its actions to
your application. File paths are resolved against the conversation's working directory.

```swift
var host = AgentHostServices(
    directory: { workingDirectory.path },
    isLocal: { true }
)
host.openFile = { path, line, column in
    editor.open(path: path, line: line, column: column)
}
host.openBrowser = { url in browser.open(url) }
host.runCommand = { command in terminal.run(command) }
host.remoteImages = { .clickToLoad }

let conversation = AgentConversationViewController(connection: connection, host: host)
```

Local connections supply file reads and file suggestions automatically. Remote hosts
can supply their own asynchronous file service. Navigation, repository metadata,
pull request previews, and workspace labels are optional callbacks. Bind menus and
shortcuts by passing an `AgentShortcut` to `conversation.perform(_:)`.

Use `AgentTheme` to select light/dark palettes and appearance. Each controller can
receive its own theme; `followSystem()` observes appearance changes without polling.

## Own the lifecycle

Hiding a view does not cancel the agent. This allows multiple conversations and
background work. For an explicit close, first ask `canClose()`, then call
`closeConversation()` and `dispose()` after the host commits to closing it.

Before application termination:

1. Await `conversation.flushDraft()` for each controller.
2. Dispose the conversation controllers.
3. Run `workspace.shutdown()` off the main actor and wait for it to return.

Shutdown interrupts running work, saves state, finishes observers, and releases the
workspace lock. It is idempotent. The example demonstrates an AppKit termination
handler that keeps the main run loop available while the draft is saved. An agent
cannot outlive its host process without an application-owned helper or daemon.

## Use your own transport

`AgentUI` depends only on `AgentCore`. Construct an `AgentConnection` with a request
closure and an observation-stream factory, plus whichever optional services your
backend supports. Each observer must receive its own stream. Revision notifications
can coalesce; the UI reconciles authoritative snapshots and deltas.

This lets a desktop UI talk to a separate local helper or remote server while the
helper alone links `AgentRuntime`. The package has no dependency on Tab's daemon,
sockets, workspace layout, terminal engine, or application model.

## Run the example

```sh
swift run AgentKitExample
```

The default is an offline, streaming UI demo. It does not use a provider account or
make model requests. To use a real CLI:

```sh
swift run AgentKitExample --provider codex --directory /path/to/project --storage /path/to/agent-state
swift run AgentKitExample --provider claude --directory /path/to/project --storage /path/to/agent-state
# Application-tool example: ask it to change the window title.
swift run AgentKitExample --provider codex --app-tools --directory /tmp --storage /tmp/agentkit-app-demo
```

The example persists the workspace and conversation identities. To build a native
app bundle:

```sh
scripts/bundle-example.sh
open 'build/AgentKit Example.app'
```

## Validate

```sh
scripts/validate.sh
```

Validation builds with warnings as errors, runs the XCTest suites, bundles the
standalone example, and verifies its ad-hoc signature. Provider tests exercise real
local fixture subprocesses without credentials or model usage. Tests cover streaming,
protocol normalization, interruption, queues, persistence, file safety, and native
rendering, application-tool registration, retry deduplication, and cancellation. Live provider compatibility should also be checked when upgrading a CLI.

[MIT license](LICENSE). Adapted code and artwork are credited in
[third-party notices](THIRD_PARTY_NOTICES.md).

## Serve multiple projects

`AgentRuntimeService` owns a shared conversation store for hosts with multiple
projects or a socket/SSH transport. Supply a project-to-directory resolver and
optional `AgentLaunchContext` for application instructions and environment values.
Route agent requests through `handle`, `conversation`, `attachment`, `checkpoint`,
`modelCatalog`, `composerContext`, `history`, and `importHistory`. Forward revision
notifications from `changed` to remote clients, or use independent `observe` streams.
`AgentWorkspace` uses this same runtime with a single project resolver.

The service accepts an existing conversation directory directly. It preserves
snapshot, transcript, attachment, checkpoint, and queue formats; clearing archives
prior resources before resetting the original session. Call `refuseNewRequests`
before host shutdown, then `shutdown` off the main thread to flush and release the
store. `tryRefuseIfIdle` reserves shutdown atomically only when no conversation is live.

For an application-owned transport, build an `AgentConnection` and provide host
navigation through `AgentHostServices`. Implement `AgentCodedError` on transport
errors so the UI can distinguish unsupported services and missing conversations.
Tab uses all three products this way: AgentCore on its wire, AgentRuntime in its
server, and AgentUI in its desktop pane adapter.

## Conversation commands

Use `/help` for the supported commands and `/skills` to refresh installed skills.
`/clear` resets the current conversation and archives its history; `/new` opens a
conversation through the host. `/compact` uses provider compaction, `/fork` requires
a host that can open another conversation, and `/copy` and `/export` include retained
paginated history. Return executes commands; Tab completes them. Commands unavailable
in the host preserve the draft and explain the limitation.
