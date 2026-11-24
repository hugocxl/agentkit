# AgentKit

Native Swift package for macOS 14+ on Apple silicon with three library products: `AgentCore`, `AgentRuntime`, and `AgentUI`.

## Commands

```sh
swift build
scripts/validate.sh               # warnings-as-errors build, batched tests, example bundle
scripts/bundle-example.sh         # build build/AgentKit Example.app (isolated in worktrees)
scripts/stop.sh                   # quit this checkout's example app
cd website && npm ci && npm run build:site && npm run check:site
```

A change is finished only when `scripts/validate.sh` passes. If a task opened the example app, run `scripts/stop.sh` before finishing.

## Why & Invariants

- **Strict module boundaries:** `AgentCore` owns portable conversation records and transport contracts; `AgentRuntime` depends only on `AgentCore` and Apple frameworks (no AppKit or Tab dependencies); `AgentUI` depends only on `AgentCore`, Apple frameworks, and `@hugocxl/icons` (no runtime dependency).
- **Host-agnostic design:** never introduce app-specific project stores, sockets, pane layouts, or settings. Host integrations belong in `AgentHostServices`; backend integrations use `AgentConnection`. Keep AppKit rendering primary (SwiftUI is only an embedding wrapper).
- **Persistence & safety:** persistence must tolerate missing optional fields and preserve transcript/queue compatibility. No force unwraps or `try!` outside tests.
- **Offline CI testing:** test subprocess and lifecycle risks with fixture providers — never require credentials in CI. `scripts/test-batches.py` bounds fixture processes because AppKit defers native text-view cleanup.
- **Version parity:** keep `AgentKitVersion`, example bundle version, `CHANGELOG.md`, and install snippet in `website/content/INTEGRATION.md` in agreement.
- **Worktrees & website:** linked worktrees give `AgentKit Example.app` a unique bundle ID via `scripts/worktree.sh`. All website tooling and docs live inside `website/` (no root `package.json` or `docs/`). Never use bare `git stash`.

## Commits & Releases

- Commit and push only when asked.
- Commit messages must use `<Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence.>` (enforced by `.githooks/commit-msg`, which automatically prepends `CHANGELOG.md` and triggers `.githooks/post-commit` to tag `vX.Y.Z`).
- Every push to `main` validates, pushes new `vX.Y.Z` tags, and publishes GitHub Releases automatically. Do not tag by hand.
