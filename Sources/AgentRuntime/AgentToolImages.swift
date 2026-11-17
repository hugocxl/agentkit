import AgentCore
import CryptoKit
import Foundation

/// the source renderer's first eight raster image blocks, in asset-index order. Blob bytes stay
/// out of chat snapshots; the session owner stores them before publishing metadata.
internal enum AgentToolImages {
    struct Projection {
        var output: Any?
        var images: [AgentChatAttachment]
        var replacements: [AgentProviderJSON.Replacement] = []
    }
    static func project(_ output: Any?) -> Projection {
        var images: [AgentChatAttachment] = []
        var replacements: [AgentProviderJSON.Replacement] = []
        func block(_ value: Any, path: [AgentProviderJSON.Component]) -> Any {
            guard let original = value as? [String: Any] else { return value }
            var value = original
            if value["type"] as? String == "inputImage", let url = value["imageUrl"] as? String {
                guard url.hasPrefix("data:"), let separator = url.range(of: ";base64,") else { return original }
                value = ["type": "image", "mimeType": String(url[url.index(url.startIndex, offsetBy: 5)..<separator.lowerBound]),
                         "data": String(url[separator.upperBound...])]
            }
            guard value["type"] as? String == "image" else { return original }
            let source = value["source"] as? [String: Any]
            if let source, source["type"] as? String != "base64" { return value }
            guard let mime = (source == nil ? value["mimeType"] : source?["media_type"]) as? String,
                  AgentAttachments.imageTypes.contains(mime.lowercased()) else { return value }
            guard images.count < 8 else {
                let value = ["type": "image", "mimeType": mime.lowercased()]
                replacements.append(.init(path: path, json: agentRuntimeStructuredJSON(value) ?? "{}"))
                return value
            }
            let encoded = (source == nil ? value["data"] : source?["data"]) as? String
            let limit = ((AgentChatAttachment.maxPayloadBytes + 2) / 3) * 4
            let data = encoded.flatMap { $0.utf8.count <= limit ? Data(base64Encoded: $0) : nil } ?? Data()
            let bytes = data.count <= AgentChatAttachment.maxPayloadBytes ? data : Data()
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            images.append(.init(id: "tool-image-\(images.count)-\(digest)", name: "Tool output image", mimeType: mime.lowercased(), data: bytes))
            replacements.append(.init(path: path, json: "{\"type\":\"text\",\"text\":\"\"}"))
            return ["type": "text", "text": ""]
        }
        if let values = output as? [Any] {
            let cleaned = values.enumerated().map { block($0.element, path: [.index($0.offset)]) }
            return Projection(output: cleaned, images: images, replacements: replacements)
        }
        if var object = output as? [String: Any], object["type"] == nil {
            for key in ["content", "contentItems"] {
                if let content = object[key] as? [Any] {
                    object[key] = content.enumerated().map { block($0.element, path: [.key(key), .index($0.offset)]) }
                }
            }
            return Projection(output: object, images: images, replacements: replacements)
        }
        if let output {
            let cleaned = block(output, path: [])
            return Projection(output: cleaned, images: images, replacements: replacements)
        }
        return Projection(output: nil, images: [])
    }

    static func directoryName(item: String) -> String {
        if UUID(uuidString: item) != nil { return item }
        return "tool-" + SHA256.hash(data: Data(item.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
