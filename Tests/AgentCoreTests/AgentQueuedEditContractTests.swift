import AgentCore
import Foundation
import XCTest

final class AgentQueuedEditContractTests: XCTestCase {
    func testUpdateQueuedRoundTripsAndValidates() throws {
        let added = AgentChatAttachment(name: "After.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let request = AgentChatRequest.updateQueued(session: SessionId(), id: UUID().uuidString,
            edit: .init(text: "", settings: .init(model: "m", effort: nil, planMode: true), attachments: [.keep(id: "kept"), .add(added)]),
            expectedRevision: 4)
        XCTAssertNoThrow(try request.validate(), "An attachment-only edit is valid")
        let decoded = try JSONDecoder().decode(AgentChatRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testInvalidEditsAreRefusedBeforeReachingTheQueue() {
        let id = UUID().uuidString
        let file = AgentChatAttachment(id: "same", name: "a.txt", mimeType: "text/plain", data: Data("a".utf8))
        for edit in [
            AgentQueuedEdit(text: "  ", attachments: []),
            AgentQueuedEdit(text: "x", attachments: [.keep(id: "same"), .add(file)]),
            AgentQueuedEdit(text: "x", attachments: Array(repeating: .keep(id: "k"), count: 2)),
            AgentQueuedEdit(text: String(repeating: "é", count: 40_000), attachments: []),
            AgentQueuedEdit(text: "x", attachments: (0...AgentChatAttachment.maxCount).map { .keep(id: "k\($0)") }),
        ] {
            XCTAssertThrowsError(try AgentChatRequest.updateQueued(session: SessionId(), id: id, edit: edit, expectedRevision: 0).validate())
        }
        XCTAssertThrowsError(try AgentChatRequest.updateQueued(session: SessionId(), id: "not-a-uuid",
                                                               edit: .init(text: "x", attachments: []), expectedRevision: 0).validate())
    }

    func testOlderRequestsAndCapabilitiesKeepTheirShape() throws {
        let edit = AgentChatRequest.editQueued(session: SessionId(), id: UUID().uuidString, text: "t", expectedRevision: 1)
        XCTAssertEqual(try JSONDecoder().decode(AgentChatRequest.self, from: JSONEncoder().encode(edit)), edit)
        XCTAssertTrue(AgentCapabilities.all.contains(.steering))
        XCTAssertFalse(AgentCapabilities([.promptQueue]).contains(.steering), "Hosts that list capabilities opt in to Send Now")
        XCTAssertEqual(AgentShortcut(rawValue: "sendAgentPromptNow"), .sendAgentPromptNow)
        XCTAssertTrue(AgentSlashCommand.localNames.isSuperset(of: ["stash", "stashes", "clear", "clear-draft"]))
    }
}
