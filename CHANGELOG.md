# Changelog

## 1.3.0 - 2026-11-17

### Added

- Let the host show AgentKit's notices with its own, and forward runtime errors to its log.
- Let the host say how to update a backend that predates a service, through `AgentConnection.backendAdvice`.
- Let a host that owns its store exclusively serve it when the runtime can't lock it, through `hostOwnsStore`.

### Fixed

- Encode a workspace's application tools before its store opens, so tools that can't be encoded leave no checkpoint recovery running.
- Draw provider marks, branded link icons in prose, footnotes, tables and reports, and icon buttons in the conversation's theme instead of the shared default, including after the host replaces it with another theme of the same colors.
- Read repository identity once per connection, so folders outside Git are no longer probed on every update.
- Stop providers without holding a cooperative thread, stop them together at shutdown, and wait there for every provider to exit, including ones being retired or replaced and the ones discovering models and commands, so none outlives its host; shutdown also waits until checkpoints being taken and reverts under way are written, even when called from every Swift task worker at once, and changes nothing for a revert or close asked for after it begins.
- List provider history off the cooperative pool.
- Discover commands from CLIs installed after the runtime started, as new conversations already do.
- Move an expired conversation's record aside before removing its resources, so a failed removal never leaves a record pointing at missing files, and finish a removal cut short at a later start, including files out of reach and checkpoint refs Git couldn't remove yet.
- Keep a cleared conversation's archived checkpoints when the conversation it cleared is deleted or cleared again after an interrupted clear, waiting while the archive can't be read; an archive itself can't be cleared.
- Copy everything again when retrying a clear that stopped while copying, so the archive is whole before the conversation's own files go, and reclaim what the stopped copy left.
- Remove a checkpoint's Git ref from the repository that keeps it, even once its folder or worktree is gone, only in a repository the user owns and never through a ref that links elsewhere, keep a ref Git can't reach for a later try, keep track of one Git made before failing, and count a removal Git made before failing; a ref Git may or may not have made is never a checkpoint, and refs no checkpoint uses that Git couldn't remove yet are removed at the next start.
- Show image copy and save feedback in the conversation, or the expanded viewer, in its theme, when the host and window show no notices.
- Keep expanded images, diagrams, file previews, the windows showing a turn's or a tool's changes or an agent's steps, and the pickers, editors, confirmations, context details and attachment previews open over a conversation in its theme and appearance when the theme is replaced or changes in place, and close an expanded image or diagram with the conversation, file preview or agent's steps it came from.
- Close a conversation's HTML previews, media players, project file previews and confirmations when it goes, open none it was still loading, and never send a revert confirmed after it went.
- Name the running application, not Tab, in microphone and speech permission errors and unsupported-request replies.
- Load link icons, in transcripts and the windows showing their content, only where the conversation's remote-image setting allows it, rather than following the last conversation configured.
- Apply a revert in turn with the conversation's checkpoints and turns: a message sent meanwhile starts after it, a clear waits for it or is refused, and none starts while an agent works, in the foreground or the background, or any provider process in its folder, in a folder inside or around it, or working there now after a folder moved, however the folders are spelled, is starting or still exits, including one a cleared conversation had, one a provider replaced, one that failed, one ended for output past its limit and one started to discover models or commands.
- Keep a clear and a history import into the same conversation from overlapping, never answer an import with a conversation being cleared, and remove the images of an import that isn't made.
- Write a message's files as soon as it is admitted, in order with clears and cleanups of the conversation's files, so a conversation cleared right after a message was stopped archives them whole.
- Refuse pasted images, drafts with attachments and retries of messages with attachments in conversations whose backend takes none, keeping the draft as written.
- Never deliver a follow-up the user stopped before the agent took it, into that turn or one the agent starts later, nor send it again as a turn of its own; one whose turn ends first is answered as never sent rather than delivered, and one that may have reached the agent as it failed.
- Write nothing to a store once shutdown hands it over, however late a request, an import, a tool's images or a model catalog finish.
- Continue a past conversation beside one in use, or open the one already continuing it, only where the host can show it; elsewhere the pane explains instead of importing it out of sight.
- Start each provider, and tell Codex to work, in the physical folder it launched in, so a link on the way pointed elsewhere meanwhile can't move its work.
- Show runtime errors' own messages, such as a conversation too large to open, as their `localizedDescription`.
- Keep a tool's whole output within its reply: cut between characters, and within half a frame however much escaping it needs, as earlier-message pages now are too; outputs kept cut inside a character read as whole characters.
- Run the host's change and activity callbacks in order on a queue of their own, so one can call back into the service, even to shut it down, and a slow one no longer holds up every conversation.
- Kill a provider ended for output past its limit once it takes no notice, as a stopped one is, so it can't hold reverts in its folder.

## 1.2.1 - 2026-11-17

### Fixed

- Validate with the Xcode 27 SDK used for development and host releases instead of the hosted runner default.

## 1.2.0 - 2026-11-17

### Added

- Embed conversations on the host background while preserving composer styling.
- Bound application-tool execution with explicit scheduling, independent reads and revocable turn-scoped commit authority.
- Show queued and timed-out tool states, retain large arguments for inspection, and refresh provider threads when application contracts change.

### Fixed

- Retire pending host tools when turns complete, fail or are interrupted without waiting for unresponsive workers.
- Preserve application-owned results and image attachments against provider echoes, including Codex data-URL images.
- Preserve successful execution outcomes when presentation limits are exceeded.
- Compare archived checkpoint records semantically when recovering interrupted conversation clears.

## 1.1.0 - 2026-11-16

### Added

- Host multiple projects in one durable runtime with independent change observers and exclusive storage ownership.
- Browse provider commands and skills with descriptions, aliases, arguments, and refreshable discovery.
- Fork conversations, export their retained history, and inspect background shell tasks.
- Integrate conversation mentions, custom themes, and versioned file services from the embedding application.

### Fixed

- Clear a conversation in place while preserving its prior messages and resources in an archive.
- Route compaction and review through the provider, and refresh context usage after compaction.
- Resolve skills when accepting a prompt and keep retries from repeating discovery or delivery.
- Preserve invalid command drafts and respect the embedding application’s supported commands.

## 1.0.0 - 2026-11-16

### Added

- Embed native AI conversations in AppKit and SwiftUI applications.
- Run Claude Code and Codex through local CLI providers with persistent conversations.
- Register application tools once for both providers, with ordered execution, cancellation and image results.
- Connect application-owned file, navigation, and transport services.
- Explore the standalone example without a provider account using its offline demo.
