# Integration verification

Validated on Apple silicon with Xcode 27 and macOS 27, 2026-11-16.

- `scripts/validate.sh`: warnings-as-errors build, XCTest suites, standalone example
  app bundle and signature verification passed.
- Filmatte consumed the sibling package through SwiftPM in its Xcode app and Swift 6
  core package. Its `scripts/validate.sh` passed, including 133 core tests and the
  warnings-as-errors app build and bundle checks.
- Filmatte's opt-in `LiveAgentTests` ran Claude Code 2.1.311 and Codex CLI 0.166.0.
  Each provider discovered the application's editing tools, added a text overlay,
  removed two seconds from the test timeline, and completed the turn. Tests used an
  isolated project; CI requires no provider account or model requests.
- The native Filmatte test app displayed streamed replies and a title edit on a
  generated video project. A `view_frame` call returned a JPEG to the model and the
  native tool inspector. The saved conversation appeared after app relaunch.
- Filmatte's screenshot script captured the relaunched test window, and the image
  was visually inspected. The test bundle had a separate bundle identifier.

The automated runtime fixtures separately check application-tool discovery,
permission restrictions, unknown tools, duplicate call IDs, image results,
cancellation, persistence, and independent change observers. Rendering tests retain
Tab's transcript, Markdown, diagram, composer, and virtualization coverage.

These checks establish local integration with the listed CLI versions. New provider
versions can change their protocols; rerun the live consumer checks when upgrading.
The package's GitHub validation workflow exercises offline tests on macOS 26.
