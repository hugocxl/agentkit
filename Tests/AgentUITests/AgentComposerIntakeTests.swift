import AgentCore
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AgentRuntime
@testable import AgentUI

private actor ImportGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Long pastes (C1), imports bound to their draft (C2) and optimized images (C7).
@MainActor
final class AgentComposerIntakeTests: XCTestCase {
    private func harness() throws -> ComposerHarness {
        let harness = try ComposerHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        return harness
    }

    private func small(_ name: String, bytes: Int = 8) -> AgentDraftAttachment {
        AgentDraftAttachment(name: name, mimeType: "text/plain", data: Data(repeating: 65, count: bytes))
    }

    private func paste(_ text: String, into pane: AgentPaneController) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pane.surface.composer.paste(nil)
    }

    // MARK: C1

    func testLongPasteAtTheSlotLimitGoesInlineAndSaysWhy() throws {
        let h = try harness()
        let pane = h.pane()
        pane.draftAttachments = (0..<AgentChatAttachment.maxCount).map { small("File \($0).txt") }
        let long = (1...250).map { "line \($0)" }.joined(separator: "\n")
        guard case .inline(let reason?) = pane.attachLongPaste(long) else { return XCTFail("It goes inline") }
        XCTAssertTrue(reason.contains("already has \(AgentChatAttachment.maxCount) attachments"), reason)
        XCTAssertEqual(pane.notice?.text.hasSuffix("The paste was inserted as text instead."), true)
        XCTAssertEqual(pane.draftAttachments.count, AgentChatAttachment.maxCount)
        paste(long, into: pane)
        XCTAssertEqual(pane.surface.composer.string, long, "The text view inserts what intake let through")
    }

    func testLongPastePastTheByteBudgetAndMessageLimitIsRejectedWithoutChangingTheDraft() throws {
        let h = try harness()
        let pane = h.pane()
        pane.draftAttachments = [small("Big.txt", bytes: AgentChatAttachment.maxTotalBytes - 1000)]
        pane.surface.composer.string = "Keep me"
        let fits = String(repeating: "a", count: 11_000)
        XCTAssertEqual(pane.attachLongPaste(fits), .inline("It would bring the draft's attachments over 8 MB."))
        // 17,000 characters but 68,000 bytes: the message limit counts bytes.
        let emoji = String(repeating: "😀", count: 17_000)
        guard case .rejected(let message) = pane.attachLongPaste(emoji) else { return XCTFail("It can't be added") }
        XCTAssertTrue(message.contains("64 KB message limit"), message)
        XCTAssertEqual(pane.notice?.kind, .warning)
        pane.surface.composer.setSelectedRange(NSRange(location: 7, length: 0))
        paste(emoji, into: pane)
        XCTAssertEqual(pane.surface.composer.string, "Keep me")
        XCTAssertEqual(pane.draftAttachments.map(\.name), ["Big.txt"])
    }

    func testMultibyteLongPasteIsAttachedWithItsExactBytesOnce() throws {
        let h = try harness()
        let pane = h.pane()
        let text = String(repeating: "é", count: 10_000)
        XCTAssertEqual(pane.attachLongPaste(text), .attached)
        XCTAssertEqual(pane.draftAttachments.map(\.data), [Data(text.utf8)])
        XCTAssertEqual(pane.notice?.text, "The long paste was attached as a text file.")
        XCTAssertEqual(pane.attachLongPaste(text), .attached)
        XCTAssertEqual(pane.notice?.text, "This text is already attached.")
        XCTAssertEqual(pane.draftAttachments.count, 1)
        paste(text, into: pane)
        XCTAssertEqual(pane.surface.composer.string, "", "An attached paste is not also inserted")
    }

    func testWithoutAttachmentsALongPasteGoesInlineOnlyWhenItFits() throws {
        let h = try harness()
        let pane = h.pane()
        pane.capabilities.remove(.attachments)
        XCTAssertEqual(pane.attachLongPaste(String(repeating: "b", count: 12_000)), .inline(nil))
        guard case .rejected = pane.attachLongPaste(String(repeating: "b", count: 70_000)) else { return XCTFail("Too long for a message") }
    }

    // MARK: C2

    func testClearingTheDraftDropsImportsThatFinishLater() async throws {
        let h = try harness()
        let draft = h.root.appendingPathComponent("drafts/conversation.json")
        let pane = h.pane(draft: draft)
        pane.refresh()
        try await h.until { pane.snapshot != nil && !pane.restoringDraft }
        let first = ImportGate(), second = ImportGate()
        let old1 = small("Old one.txt"), old2 = small("Old two.txt")
        pane.prepareAttachments { await first.wait(); return AgentAttachmentIntake(attachments: [old1]) }
        pane.prepareAttachments { await second.wait(); return AgentAttachmentIntake(attachments: [old2]) }
        XCTAssertEqual(pane.preparingAttachments, 2)
        pane.surface.composer.string = "/clear-draft"
        pane.send()
        XCTAssertEqual(pane.preparingAttachments, 0, "Clearing ends queued and running imports")
        pane.surface.composer.string = "A new prompt"
        pane.saveDraft(immediate: true)
        await first.release()
        await second.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(pane.draftAttachments.isEmpty)
        try await pane.flushDraft()
        let saved = try JSONDecoder().decode(AgentSavedDraft.self, from: Data(contentsOf: draft))
        XCTAssertEqual(saved.text, "A new prompt")
        XCTAssertTrue(saved.attachments.isEmpty)
        let server = try await h.read()
        XCTAssertNil(server.resetID, "/clear-draft never clears the conversation")
    }

    func testClearArchivesTheConversationInPlaceAndKeepsDraftAttachments() async throws {
        let h = try harness()
        let pane = h.pane()
        pane.refresh()
        try await h.until { pane.snapshot != nil }
        let kept = small("Kept.txt")
        pane.draftAttachments = [kept]
        pane.surface.composer.string = "/clear"
        pane.send()
        _ = try await h.settle { $0.resetID != nil }
        try await h.until { pane.snapshot?.resetID != nil }
        XCTAssertEqual(pane.draftAttachments.map(\.id), [kept.id])
        XCTAssertEqual(pane.surface.composer.string, "")
    }

    func testDisposingDropsPendingImports() async throws {
        let h = try harness()
        let pane = h.pane()
        let gate = ImportGate(), late = small("Late.txt")
        pane.prepareAttachments { await gate.wait(); return AgentAttachmentIntake(attachments: [late]) }
        pane.dispose()
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pane.draftAttachments.isEmpty)
        XCTAssertEqual(pane.preparingAttachments, 0)
    }

    // MARK: C7

    private func image(width: Int, height: Int, alpha: Bool = false, noise: Bool = true, type: UTType = .png, frames: Int = 1) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            var pixels = [UInt8](repeating: 128, count: width * height * 4)
            if noise { for index in pixels.indices { pixels[index] = UInt8.random(in: 0...255, using: &generator) } }
            let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func size(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    func testOversizedScreenshotFitsAfterOptimization() throws {
        let screenshot = try image(width: 900, height: 700)
        XCTAssertGreaterThan(screenshot.count, 400_000)
        let optimized = try AgentImageOptimizer.optimize(data: screenshot, name: "Screen Shot.png", budget: 300_000)
        XCTAssertLessThanOrEqual(optimized.data.count, 300_000)
        XCTAssertEqual(optimized.mimeType, "image/jpeg")
        XCTAssertEqual(optimized.name, "Screen Shot (optimized).jpeg")
        let (width, height) = try XCTUnwrap(size(of: optimized.data))
        XCTAssertLessThanOrEqual(width, 900)
        XCTAssertEqual(Double(width) / Double(height), 900.0 / 700.0, accuracy: 0.02, "The aspect ratio holds")
        XCTAssertNotNil(optimized.thumbnail)
        let transparent = try AgentImageOptimizer.optimize(data: try image(width: 800, height: 800, alpha: true, noise: false), name: "Icon.png", budget: 50_000)
        XCTAssertEqual(transparent.mimeType, "image/png", "Transparency keeps a format that holds it")
    }

    func testOversizedDimensionsAndUndecodableDataFailClearly() throws {
        let screenshot = try image(width: 900, height: 700, noise: false)
        XCTAssertThrowsError(try AgentImageOptimizer.optimize(data: screenshot, name: "Wide.png", budget: 1000,
                                                              limits: .init(pixels: 100_000))) { error in
            XCTAssertEqual(error as? AgentImageOptimizationError, .dimensionsTooLarge("Wide.png", width: 900, height: 700))
            XCTAssertTrue(error.localizedDescription.contains("900 × 700"))
        }
        XCTAssertThrowsError(try AgentImageOptimizer.optimize(data: Data("not an image".utf8), name: "Junk.png", budget: 1000)) { error in
            XCTAssertEqual(error as? AgentImageOptimizationError, .undecodable("Junk.png"))
        }
        XCTAssertThrowsError(try AgentImageOptimizer.optimize(data: screenshot, name: "Huge.png", budget: 1000, limits: .init(sourceBytes: 100))) { error in
            XCTAssertEqual(error as? AgentImageOptimizationError, .sourceTooLarge("Huge.png"))
        }
        let animation = try image(width: 40, height: 40, type: .gif, frames: 2)
        XCTAssertThrowsError(try AgentImageOptimizer.optimize(data: animation, name: "Clip.gif", budget: 100)) { error in
            XCTAssertEqual(error as? AgentImageOptimizationError, .animated("Clip.gif"))
        }
        XCTAssertThrowsError(try AgentImageOptimizer.optimize(data: try image(width: 600, height: 600), name: "Noise.png", budget: 200)) { error in
            XCTAssertEqual(error as? AgentImageOptimizationError, .cannotFit("Noise.png"))
        }
    }

    func testOptimizationStopsWhenCancelled() async throws {
        let big = try image(width: 1600, height: 1600)
        let task = Task.detached {
            try await AgentImageOptimizer.optimize(.init(name: "Big.png", source: .data(big), byteCount: big.count), budget: 500)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled optimization produces nothing") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testOrdinaryImagesKeepTheirOriginalPixels() async throws {
        let h = try harness()
        let pane = h.pane()
        var offers = 0
        pane.composerWork.offerImageOptimization = { _, _ in offers += 1; return true }
        let png = try image(width: 40, height: 30)
        pane.surface.composer.onAttachImage?(png, "image/png")
        try await h.until { pane.draftAttachments.count == 1 }
        XCTAssertEqual(pane.draftAttachments.first?.data, png)
        XCTAssertEqual(offers, 0)
    }

    func testOversizedPasteOffersAnOptimizedCopyThatCanBeDeclined() async throws {
        let h = try harness()
        let pane = h.pane()
        let screenshot = try image(width: 1800, height: 1700)
        XCTAssertGreaterThan(screenshot.count, AgentChatAttachment.maxFileBytes)
        var answers = [false, true], details: [String] = []
        pane.composerWork.offerImageOptimization = { _, detail in details.append(detail); return answers.removeFirst() }
        pane.surface.composer.onAttachImage?(screenshot, "image/png")
        try await h.until { details.count == 1 && pane.preparingAttachments == 0 }
        XCTAssertTrue(pane.draftAttachments.isEmpty, "Declining attaches nothing")
        XCTAssertTrue(details[0].contains("“Pasted image”"), details[0])
        pane.surface.composer.onAttachImage?(screenshot, "image/png")
        try await h.until { pane.draftAttachments.count == 1 }
        let optimized = try XCTUnwrap(pane.draftAttachments.first)
        XCTAssertEqual(optimized.name, "Pasted image (optimized).jpeg")
        XCTAssertLessThanOrEqual(optimized.data.count, AgentChatAttachment.maxFileBytes)
    }

    func testIntakeSetsAsideOversizedImageFilesOnly() async throws {
        let h = try harness()
        let folder = h.root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("Shot.png"), text = folder.appendingPathComponent("Log.txt")
        try image(width: 30, height: 30).write(to: png)
        try Data(repeating: 65, count: 500).write(to: text)
        let intake = try await AgentAttachmentImporter.intake(urls: [png], maximumFileSize: 100)
        XCTAssertEqual(intake.oversizedImages.map(\.name), ["Shot.png"])
        XCTAssertTrue(intake.attachments.isEmpty)
        do {
            _ = try await AgentAttachmentImporter.intake(urls: [text], maximumFileSize: 100)
            XCTFail("Only images have an optimized copy")
        } catch AgentAttachmentImportError.tooLarge {}
        let optimized = try await AgentImageOptimizer.optimize(try XCTUnwrap(intake.oversizedImages.first), budget: 100_000)
        XCTAssertEqual(optimized.mimeType, "image/jpeg")
    }

    func testPreparationShowsWhatItDoesAndCanBeStopped() async throws {
        let h = try harness()
        let pane = h.pane()
        let gate = ImportGate(), shot = small("Shot.txt")
        pane.prepareAttachments("Optimizing “Shot.png” to fit the attachment limit…") {
            await gate.wait(); return AgentAttachmentIntake(attachments: [shot])
        }
        XCTAssertEqual(pane.surface.feedback.stringValue, "Optimizing “Shot.png” to fit the attachment limit…")
        XCTAssertFalse(pane.surface.dismissNotice.isHidden)
        XCTAssertEqual(pane.surface.dismissNotice.accessibilityLabel(), "Stop preparing attachments")
        XCTAssertFalse(pane.surface.send.isEnabled)
        pane.surface.dismissNotice.onPress?()
        XCTAssertEqual(pane.preparingAttachments, 0)
        XCTAssertEqual(pane.notice?.text, "Stopped preparing attachments. Your draft is unchanged.")
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pane.draftAttachments.isEmpty)
    }
}
