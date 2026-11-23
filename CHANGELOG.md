# Changelog

## 1.5.0 - 2026-11-23

### Added

- Run Antigravity CLI, Gemini CLI, OpenCode, Grok, Kiro and any Agent Client Protocol agent beside Claude Code and Codex, through the new `AgentChatProvider` kinds and their `AgentProviderSpec`.
- Configure more than one provider of a kind, each with its own executable, home folder, arguments, environment, accent color, auto-compact threshold and model preferences, through `AgentProviderStore` and its `agent-providers.json`; start a conversation on one with `connect(provider:providerID:)`.
- Check whether each provider's CLI is installed and signed in, install or update it with `maintain`, and say in the model menu why a provider can't run.
- Sign a second Codex account in from a shadow home that shares the main home's conversations, skills and settings.
- Read Claude and Codex plan usage limits through `usageLimits` on `AgentWorkspace`, `AgentRuntimeService` and `AgentConnection`.
- Drop files anywhere on a conversation, which highlights as a whole while a file is over it.

### Changed

- Stream replies by parsing only the unfinished tail after each finished block, and fade new words in.
- Load earlier messages by themselves as the reader scrolls toward them, keep the whole archive instead of the first 64 MiB, and read it through a line index; the transcript rebuilds only from the first changed turn.
- Give every attachment one look: files as cards above the message, images as a mosaic, and sent images shown at once instead of downloaded back.
- Label tool calls by what they did, and show the quoted words of a sent quote.
- Show only the time in the working line, and restyle the activity and notices above the composer.
- Draw icons as outlines; `AppIcon.Artwork` still offers the two-tone set.
- `AgentChatRequest.send` carries the provider ID, so a host that matches it gains one more value to bind.
- Publish the command reference, the integration verification and the changelog on the website beside the docs.

### Fixed

- Keep an Antigravity turn open while work it started outlives the prompt.

## 1.4.3 - 2026-11-19

### Changed

- Take `Icons` from the `hugocxlStack` Swift package in the hugocxl/stack monorepo (`https://github.com/hugocxl/stack.git`, 0.1.4), which replaces the hugocxl/icons repository.

## 1.4.2 - 2026-11-19

### Changed

- Tag each release `vX.Y.Z` on GitHub and publish it with its changelog notes once validation passes, so Swift Package Manager can resolve every version.

## 1.4.1 - 2026-11-18

### Changed

- Refer to the icon library by its package name, @hugocxl/icons.

## 1.4.0 - 2026-11-18

### Added

- Send a prompt into the running turn with Send Now, through the `steering` capability and `AgentShortcut.sendAgentPromptNow`, while Return still queues it.
- Edit a queued prompt's text, settings and attachments together with `updateQueued`, keeping an edit the backend didn't take to retry, copy or stash.
- Stash unfinished drafts with `/stash` and restore them with `/stashes`, keeping citations, review comments, settings and attachments.
- Offer an optimized copy of an image too large to attach.
- Search a conversation's archived history from Find and reveal the matching message.
- Save each child agent's steps, bounded and pageable through `subagentStepsPage`, so they outlive the provider and the runtime.
- Keep closed conversations under a host-chosen `AgentConversationRetention`, and list, reopen, archive and delete them through `AgentConnection.library`.
- Show Codex permission requests and MCP elicitation forms as native cards that offer the provider's own decisions, answered with `.decide`.
- Keep a usage limit's reset time on the turn it stopped, with Retry and Resume at Reset through `.retryTurn` and `.scheduleRetry`.
- Rewind a Claude conversation to an earlier message with `.rewind`, archiving it whole and restoring files only when asked.
- Report each turn's checkpoint as recording, ready, unavailable or outside Git, with `.retryCheckpoint` when its baseline remains.
- Announce approvals, questions, failures and finished turns to VoiceOver once.

### Changed

- Restore files only while no other conversation or child agent works in the same physical folder, all or nothing, naming any file that couldn't be put back.
- Read review context and saved comment positions from the checkpoint rather than the working copy.
- Parse streamed responses from the last finished block instead of from the start.

### Fixed

- Report what a long paste actually did, and drop imports and restored attachments that finish after their draft was cleared.
- Keep loaded earlier messages in place across trims and reconnects.
- Keep code lines visible while streaming tilde and longer fences.
- Refresh an agent's steps window when a step changes in place.
- Clear a question's selected option when the user types an answer, and the typed answer when they choose an option.
- Expire requests from a child agent that has ended instead of answering them.

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
