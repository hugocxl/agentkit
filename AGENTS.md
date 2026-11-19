# AgentKit

AgentKit is one native Swift package for macOS 14+ on Apple silicon, with three
library products: AgentCore, AgentRuntime, and AgentUI.

- AgentCore owns portable conversation records and transport contracts.
- AgentRuntime depends only on AgentCore and Apple frameworks. No AppKit or Tab dependencies.
- AgentUI depends only on AgentCore, Apple frameworks, and @hugocxl/icons. No runtime dependency.
- Keep the existing AppKit rendering and behavior. SwiftUI is an embedding wrapper.
- Do not introduce application-specific project stores, sockets, pane layouts, or settings.
- Host integrations belong in AgentHostServices; backend integrations use AgentConnection.
- Persistence must tolerate missing optional fields. Preserve transcript and queue compatibility.
- Keep public API narrow, documented, and usable by the standalone example.
- No force unwraps or try! outside tests. Protect process, queue, and persistence ownership.
- Test subprocess and lifecycle risks with fixture providers; do not require credentials in CI.
- A change is finished only when scripts/validate.sh passes.
- Keep AgentKitVersion, example bundle version, changelog, install snippet in docs/INTEGRATION.md, and release tags in agreement.
- A commit that adds a changelog version releases it. After a push to main validates, CI tags the commit `vX.Y.Z` and publishes a GitHub release with its changelog section. Don't tag by hand; a version without a tag means its validation failed, so fix the cause.
- The README stays product-facing; integration detail lives in docs/INTEGRATION.md, which the website renders.
- The website in website/ uses only @hugocxl/design-system, with icons from @hugocxl/icons and figures from @hugocxl/vectors, all npm dev dependencies the build reads from node_modules. Check it with `npm run build:site && npm run check:site`.
- Commit or publish only when requested.
