import CryptoKit
import Foundation

/// Mirrors `slides_to_video.tools` so cache keys written by the CLI stay valid in the app.
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

    /// The manifest format written before version 0.2, which hashed only the text.
    public static func legacyTextHash(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
