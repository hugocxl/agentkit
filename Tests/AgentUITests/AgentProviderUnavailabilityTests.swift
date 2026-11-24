import AgentCore
import XCTest
@testable import AgentUI

final class AgentProviderUnavailabilityTests: XCTestCase {
    func testTheModelMenuSaysWhyAProviderCantRun() {
        let codex = AgentProviderConfig.builtIn(.codex)
        let signedOut = AgentProviderHealth(provider: "codex", installed: true, version: "0.171.0", auth: .signedOut,
                                            message: "Run `codex login` in a terminal to sign in.", checkedAt: Date(),
                                            signInCommand: "codex login")
        let reason = AgentProviderUnavailability(codex, health: signedOut)
        XCTAssertEqual(reason?.badge, "Signed out")
        XCTAssertEqual(reason?.detail, "Codex: Unavailable. Run `codex login` in a terminal to sign in.")
        XCTAssertEqual(reason?.signInCommand, "codex login")

        let ready = AgentProviderHealth(provider: "codex", installed: true, version: "0.171.0", auth: .signedIn, checkedAt: Date())
        XCTAssertNil(AgentProviderUnavailability(codex, health: ready))
        XCTAssertNil(AgentProviderUnavailability(codex, health: nil), "an unchecked provider isn't blocked")
        let unknown = AgentProviderHealth(provider: "codex", installed: true, auth: .unknown, checkedAt: Date())
        XCTAssertNil(AgentProviderUnavailability(codex, health: unknown), "a sign-in the runtime can't read may still work")
    }
}

/// Icons draw as outlines: every UI glyph has a stroke version, and none is named as filled.
final class AgentIconStrokeSetTests: XCTestCase {
    func testEveryUIGlyphHasAStrokeVersion() {
        let missing = AppIcon.allCases.filter { !$0.hasStrokeArtwork && $0.signatureHue == nil }
        XCTAssertEqual(missing, [], "UI glyphs without a stroke version")
    }

    func testNoUIGlyphIsNamedAsFilled() {
        let filled = AppIcon.allCases.filter { "\($0)".hasSuffix("Fill") }
        XCTAssertEqual(filled, [], "Stroke icons are outlines; name them without Fill")
    }
}
