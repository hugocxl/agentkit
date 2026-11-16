import AppKit
import AgentCore
import XCTest
@testable import AgentUI

@MainActor
final class AgentFileIconTests: XCTestCase {
    func testExplicitFileLinksKeepLabelsPositionsAndCopyText() throws {
        for dark in [false, true] {
            let theme = AgentTheme(systemIsDark: dark)
            let content = AgentMarkdown.inline("[**Main**](Sources/main.swift:12:4) [Folder](Sources/) `main.swift`", theme: theme, fileLinks: true)
            XCTAssertEqual(content.string, "Main Folder main.swift")
            let links = AgentFileLinkHover.fileLinks(in: content)
            XCTAssertEqual(links.map(\.path), ["Sources/main.swift", "Sources/", "main.swift"])
            let image = try XCTUnwrap(content.attribute(.agentFileLinkImage, at: 0, effectiveRange: nil) as? NSImage)
            XCTAssertTrue(image === FileIcon.image(for: "Sources/main.swift", theme: theme))
            let url = try XCTUnwrap(content.attribute(.link, at: 0, effectiveRange: nil) as? URL)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "column" }?.value, "4")
            XCTAssertNotNil(content.attribute(.agentFileLinkImage, at: 5, effectiveRange: nil))
            XCTAssertNil(content.attribute(.agentFileLinkImage, at: 12, effectiveRange: nil), "Inferred inline code keeps its existing treatment")
        }
    }
    func testCachedMetadataRefinesDirectoryAndMimeIconsWithoutChangingLinks() throws {
        let theme = AgentTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let text = NSMutableAttributedString(attributedString: AgentMarkdown.inline("[Download](download.bin)", theme: theme, fileLinks: true))
        // A directory destination without a slash is valid when the metadata identifies it.
        let directoryURL = try XCTUnwrap(AgentResponseLink.fileURL(path: "Sources", line: nil))
        // Markdown only treats recognizable paths as files; use the canonical link for this folder.
        let canonical = NSMutableAttributedString(string: "Sources", attributes: [
            .link: directoryURL, .agentExternalLinkIdentity: "directory", .font: AppFont.system(14),
        ])
        AgentExternalLinkLayout.mark(canonical, fontSize: 14, color: theme.accent, theme: theme)
        AgentFileLinkTooltip.markIcons(canonical, theme: theme) { _ in .init(isDirectory: true, byteLength: 0, mimeType: nil) }
        let image = try XCTUnwrap(canonical.attribute(.agentFileLinkImage, at: 0, effectiveRange: nil) as? NSImage)
        XCTAssertTrue(image === FileIcon.image(for: "Sources", isDirectory: true, theme: theme))
        XCTAssertEqual(canonical.string, "Sources")
        XCTAssertEqual(canonical.attribute(.link, at: 0, effectiveRange: nil) as? URL, directoryURL)
        AgentFileLinkTooltip.markIcons(text, theme: theme) { path in
            path == "download.bin" ? .init(isDirectory: false, byteLength: 1, mimeType: "application/pdf") : nil
        }
        let download = (text.string as NSString).range(of: "Download")
        let pdf = try XCTUnwrap(text.attribute(.agentFileLinkImage, at: download.location, effectiveRange: nil) as? NSImage)
        XCTAssertTrue(pdf === FileIcon.image(for: "report.pdf", theme: theme))
    }
}
