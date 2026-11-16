# AgentKit

AgentKit is one native Swift package for macOS 14+ on Apple silicon, with three
library products: AgentCore, AgentRuntime, and AgentUI.

- AgentCore owns portable conversation records and transport contracts.
- AgentRuntime depends only on AgentCore and Apple frameworks. No AppKit or Tab dependencies.
- AgentUI depends only on AgentCore, Apple frameworks, and IconsCXL. No runtime dependency.
- Keep the existing AppKit rendering and behavior. SwiftUI is an embedding wrapper.
- Do not introduce application-specific project stores, sockets, pane layouts, or settings.
- Host integrations belong in AgentHostServices; backend integrations use AgentConnection.
- Persistence must tolerate missing optional fields. Preserve transcript and queue compatibility.
- Keep public API narrow, documented, and usable by the standalone example.
- No force unwraps or try! outside tests. Protect process, queue, and persistence ownership.
- Test subprocess and lifecycle risks with fixture providers; do not require credentials in CI.
- A change is finished only when scripts/validate.sh passes.
- Keep AgentKitVersion, example bundle version, changelog, and release tags in agreement.
- Commit or publish only when requested.
