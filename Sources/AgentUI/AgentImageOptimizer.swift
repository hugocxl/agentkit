import AgentCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Why an image could not become a copy that fits its attachment budget.
enum AgentImageOptimizationError: LocalizedError, Equatable {
    case sourceTooLarge(String)
    case dimensionsTooLarge(String, width: Int, height: Int)
    case undecodable(String)
    case animated(String)
    case cannotFit(String)
    case noBudget

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge(let name):
            return "\(name) is larger than \(AgentImageOptimizer.maximumSourceBytes / 1024 / 1024) MB, too large to optimize. Export a smaller copy first."
        case .dimensionsTooLarge(let name, let width, let height):
            return "\(name) is \(width) × \(height) pixels, too large to optimize safely. Export a smaller copy first."
        case .undecodable(let name): return "\(name) could not be read as an image, so no optimized copy was made."
        case .animated(let name): return "\(name) is animated; an optimized copy would lose its frames. Export a smaller copy first."
        case .cannotFit(let name): return "Even an optimized copy of \(name) would not fit the attachment limit."
        case .noBudget: return "This draft has no attachment space left. Remove an attachment first."
        }
    }
}

/// Makes a smaller copy of an image that is over its attachment budget, with ImageIO.
/// The source's bytes and pixel dimensions are bounded before anything is decoded, and
/// decoding happens through downsampling thumbnails, never at full resolution.
enum AgentImageOptimizer {
    /// The largest source read into memory for optimization.
    static let maximumSourceBytes = 64 * 1024 * 1024
    /// The largest source, in pixels, whose header is trusted for downsampling.
    static let maximumSourcePixels = 200_000_000
    static let maximumSourceDimension = 32_768
    /// The longest side an optimized copy starts from and the smallest it may shrink to.
    static let startingSide = 4096
    static let smallestSide = 320

    struct Limits: Sendable {
        var sourceBytes = AgentImageOptimizer.maximumSourceBytes
        var pixels = AgentImageOptimizer.maximumSourcePixels
        var dimension = AgentImageOptimizer.maximumSourceDimension
    }

    /// Reads `image` and returns a copy that fits `budget` bytes. Cancelling stops the work.
    static func optimize(_ image: AgentOversizedImage, budget: Int, limits: Limits = Limits()) async throws -> AgentDraftAttachment {
        guard budget > 0 else { throw AgentImageOptimizationError.noBudget }
        let worker = Task.detached(priority: .userInitiated) { () throws -> AgentDraftAttachment in
            let data: Data
            switch image.source {
            case .data(let bytes): data = bytes
            case .file(let url): data = try read(url, name: image.name, limit: limits.sourceBytes)
            }
            return try optimize(data: data, name: image.name, budget: budget, limits: limits)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func read(_ url: URL, name: String, limit: Int) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AgentAttachmentImportError.notRegularFile(name) }
        guard (info.fileSize ?? 0) <= limit else { throw AgentImageOptimizationError.sourceTooLarge(name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(256 * 1024, limit - data.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= limit else { throw AgentImageOptimizationError.sourceTooLarge(name) }
            data.append(chunk)
        }
        return data
    }

    static func optimize(data: Data, name: String, budget: Int, limits: Limits = Limits()) throws -> AgentDraftAttachment {
        guard budget > 0 else { throw AgentImageOptimizationError.noBudget }
        guard data.count <= limits.sourceBytes else { throw AgentImageOptimizationError.sourceTooLarge(name) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw AgentImageOptimizationError.undecodable(name) }
        guard width <= limits.dimension, height <= limits.dimension, width * height <= limits.pixels else {
            throw AgentImageOptimizationError.dimensionsTooLarge(name, width: width, height: height)
        }
        guard CGImageSourceGetCount(source) == 1 else { throw AgentImageOptimizationError.animated(name) }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let type: UTType = hasAlpha ? .png : .jpeg
        var side = min(max(width, height), startingSide)
        var quality = 0.85
        while true {
            try Task.checkCancellation()
            guard let image = thumbnail(source, side: side) else { throw AgentImageOptimizationError.undecodable(name) }
            let encoded = try encode(image, type: type, quality: quality, name: name)
            if encoded.count <= budget {
                let base = (name as NSString).deletingPathExtension
                let thumb = thumbnail(source, side: 128).map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height))) }
                return AgentDraftAttachment(name: base + " (optimized)." + (type.preferredFilenameExtension ?? "jpg"),
                                            mimeType: type.preferredMIMEType ?? "image/jpeg", data: encoded, thumbnail: thumb)
            }
            guard side > smallestSide else { throw AgentImageOptimizationError.cannotFit(name) }
            // Shrink toward the budget: area scales with the square of the side.
            let ratio = (Double(budget) / Double(encoded.count)).squareRoot() * 0.92
            side = max(smallestSide, min(side - 1, Int(Double(side) * min(0.85, max(0.4, ratio)))))
            if !hasAlpha { quality = max(0.6, quality - 0.05) }
        }
    }

    private static func thumbnail(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double, name: String) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw AgentImageOptimizationError.undecodable(name)
        }
        CGImageDestinationAddImage(destination, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentImageOptimizationError.undecodable(name) }
        return output as Data
    }
}
