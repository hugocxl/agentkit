import AgentCore
import Foundation

/// Text for replies that carry arbitrary output: within a raw limit, within an encoded
/// one once JSON escapes it, and cut between Unicode scalars, so decoding it adds nothing.
enum AgentReplyBounds {
    /// The bytes `byte` takes inside a JSON string. Slashes count as escaped, so the
    /// count never falls short of an encoder's.
    static func encodedSize(_ byte: UInt8) -> Int {
        switch byte {
        case 0x22, 0x5C, 0x2F, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return 2
        case 0..<0x20: return 6
        default: return 1
        }
    }

    /// `data` as text, without the partial characters a cut left at either end.
    static func wholeCharacters(_ data: Data) -> String {
        var bytes = data[...]
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }
        var trailing = 0
        while trailing < 3, trailing < bytes.count, bytes[bytes.endIndex - 1 - trailing] & 0xC0 == 0x80 { trailing += 1 }
        if trailing < bytes.count {
            let lead = bytes[bytes.endIndex - 1 - trailing]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if length > trailing + 1 { bytes = bytes.dropLast(trailing + 1) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `text` within both limits, keeping its end when `keepingEnd` and otherwise its
    /// start, and whether anything was cut.
    static func bounded(_ text: String, maximumBytes: Int, maximumEncodedBytes: Int, keepingEnd: Bool) -> (text: String, cut: Bool) {
        let bytes = Array(text.utf8)
        var raw = 0, encoded = 0
        if keepingEnd {
            var start = bytes.count
            while start > 0 {
                let size = encodedSize(bytes[start - 1])
                guard raw < maximumBytes, encoded + size <= maximumEncodedBytes else { break }
                raw += 1; encoded += size; start -= 1
            }
            guard start > 0 else { return (text, false) }
            // Begin at a scalar's first byte.
            while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
            return (String(decoding: bytes[start...], as: UTF8.self), true)
        }
        var end = 0
        while end < bytes.count {
            let size = encodedSize(bytes[end])
            guard raw < maximumBytes, encoded + size <= maximumEncodedBytes else { break }
            raw += 1; encoded += size; end += 1
        }
        guard end < bytes.count else { return (text, false) }
        // End before a scalar the limit would split.
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return (String(decoding: bytes[..<end], as: UTF8.self), true)
    }
}
