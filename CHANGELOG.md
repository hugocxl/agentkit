# Changelog

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
