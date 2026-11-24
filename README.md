# AgentKit

### A native AI conversation, inside your Mac app.

**A Swift package that puts a full AI conversation inside your macOS app**, powered by the Claude Code, Codex, or Agent Client Protocol CLI already installed on the Mac. Extracted from [Tab](https://hugocxl.github.io/tab/) and used by Tab and Filmatte.

[Read the docs](https://hugocxl.github.io/agentkit/docs.html) · [Changelog](CHANGELOG.md) · [Visit the website](https://hugocxl.github.io/agentkit/)

[![AgentKit's home page: a native conversation, your app's tools and local CLIs](.github/preview.png)](https://hugocxl.github.io/agentkit/)

## Highlights

- **Built for AI-first apps.** Expose your app's typed tools to Claude Code and Codex while keeping provider tools read-only or off so every change goes through your app's undo path.
- **Complete conversation UI.** Streaming Markdown, code, tables, math, diagrams, attachments, model/reasoning pickers, approvals, prompt queue, search, and persisted sessions.
- **Truly native.** Drawn in AppKit with a SwiftUI wrapper — no web view, no bundled model, and an offline demo in the example app.

## Development

Requires macOS 14+ on Apple silicon and Xcode 27.

```sh
scripts/validate.sh               # warnings-as-errors build, tests, example bundle
scripts/bundle-example.sh         # bundle build/AgentKit Example.app
scripts/stop.sh                   # quit this checkout's example app
```

Website (self-contained in `website/`):

```sh
cd website && npm ci && npm run build:site && npm run check:site
```

Linked Git worktrees isolate `AgentKit Example.app` with a checkout-unique bundle ID so parallel worktrees never collide.

## Releases

Commits follow `<Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence.>` — `.githooks/` automatically updates `CHANGELOG.md` and creates the matching `vX.Y.Z` tag. Pushing to `main` runs validation and publishes the GitHub Release automatically.

## License

AgentKit is [MIT licensed](LICENSE). Third-party attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Made by [Hugo](https://github.com/hugocxl).
