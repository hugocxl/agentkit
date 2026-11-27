import AgentCore
import AppKit
import Icons
import XCTest
@testable import AgentUI

/// UI glyphs are SF Symbols; provider logos and file-type icons come from
/// @hugocxl/icons. A misspelled or missing name would silently draw nothing.
@MainActor
final class AgentIconSourceTests: XCTestCase {
    func testEveryAppIconIsAnSFSymbol() {
        let missing = AppIcon.allCases.filter { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "AppIcon cases without an SF Symbol")
    }

    func testEveryFileTypeIconHasLibraryArtwork() {
        let rules = [FileIcon.fileNames, FileIcon.extensions, FileIcon.overrideNames,
                     FileIcon.overrideExtensions, FileIcon.languages]
        let icons = Set(rules.flatMap { $0.values }).union([.file, .folder, .folderOpen])
        for artwork in [AppIcon.Artwork.mark, .duotone] {
            let missing = icons.filter { $0.image(size: 14, artwork: artwork) == nil }.map(\.rawValue).sorted()
            XCTAssertEqual(missing, [], "File-type icons without \(artwork) artwork")
        }
    }

    func testEveryProviderLogoComesFromTheLibrary() {
        let missing = AgentChatProvider.allCases.filter {
            let mark = AgentLogo.mark($0)
            return StrokeIcon(rawValue: mark.rawValue) == nil && Icon(rawValue: mark.rawValue) == nil
        }
        XCTAssertEqual(missing.map(\.rawValue), [], "Providers without an @hugocxl/icons logo")
    }
}
