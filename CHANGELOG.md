# Changelog

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
