import CryptoKit
import Foundation

/// Truncated SHA-256 hashes for cache keys. The format must stay fixed so existing caches stay valid.
public enum Hashing {
    public static func textHash(_ parts: String...) -> String {
        textHash(parts)
    }

    public static func textHash(_ parts: [String]) -> String {
        hex(SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)))
    }

    public static func fileHash(_ url: URL) throws -> String {
        hex(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    /// Older manifests hash only the narration text. Clips with such entries are adopted.
    public static func legacyTextHash(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
