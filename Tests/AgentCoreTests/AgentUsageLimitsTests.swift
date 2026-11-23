import Foundation
import AgentCore
import XCTest

final class AgentUsageLimitsTests: XCTestCase {
    func testUsageLimitsMessagesRoundTrip() throws {
        let request = AgentUsageLimitsRequest(forceRefresh: true)
        let limits = AgentUsageLimitsReply(providers: [
            .init(provider: .claude, windows: [
                .init(id: "five_hour", kind: .session, label: "Session", usedPercent: 7, windowDurationMinutes: 300,
                      resetsAt: Date(timeIntervalSince1970: 1_795_000_000)),
                .init(id: "seven_day_fable", kind: .weekly, label: "Weekly · Fable", usedPercent: 32),
            ], checkedAt: Date(timeIntervalSince1970: 1_794_990_000)),
            .init(provider: .codex, failure: "Codex CLI is not authenticated.", checkedAt: Date(timeIntervalSince1970: 1_794_990_000)),
        ])
        XCTAssertEqual(try WireJSON.decode(AgentUsageLimitsRequest.self, from: WireJSON.encode(request)), request)
        try limits.validate()
        XCTAssertEqual(try WireJSON.decode(AgentUsageLimitsReply.self, from: WireJSON.encode(limits)), limits)
    }

    /// A newer server may report providers and window kinds this build doesn't know.
    func testReplyFromNewerServerDropsUnknownProvidersAndKinds() throws {
        let json = """
        {"providers":[
          {"provider":"future-agent","windows":[]},
          {"provider":"claude","windows":[{"id":"x","kind":"quarterly","label":"Quarterly","usedPercent":10,"extra":1}],"later":true}
        ]}
        """
        let reply = try WireJSON.decode(AgentUsageLimitsReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.providers.map(\.provider), [.claude])
        XCTAssertEqual(reply.providers.first?.windows.first?.kind, .unknown)
    }

    func testValidationRejectsDuplicateAndOutOfRangeWindows() {
        let window = AgentUsageWindow(id: "a", kind: .session, label: "Session", usedPercent: 10)
        XCTAssertThrowsError(try AgentUsageLimitsReply(providers: [.init(provider: .claude, windows: [window, window])]).validate())
        var wild = window
        wild.usedPercent = 140
        XCTAssertThrowsError(try AgentUsageLimitsReply(providers: [.init(provider: .claude, windows: [wild])]).validate())
    }
}
