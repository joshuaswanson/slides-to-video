import Foundation

public struct EngineInfo: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Runs in the Python worker, on this Mac or a remote GPU host.
        case worker(pythonVersion: String)
        case cloud
    }

    public let id: String
    public let title: String
    public let languages: Set<String>
    public let kind: Kind

    static let tenLanguages: Set<String> = ["en", "zh", "ja", "ko", "fr", "de", "es", "ar", "ru", "pt"]

    public static let all = [
        EngineInfo(id: "qwen3", title: "Qwen3-TTS", languages: tenLanguages, kind: .worker(pythonVersion: "3.12")),
        EngineInfo(id: "chatterbox", title: "Chatterbox", languages: ["en"], kind: .worker(pythonVersion: "3.11")),
        EngineInfo(id: "elevenlabs", title: "ElevenLabs (API)", languages: tenLanguages, kind: .cloud),
        EngineInfo(id: "cartesia", title: "Cartesia (API)", languages: tenLanguages, kind: .cloud),
        EngineInfo(id: "custom", title: "Custom HTTP endpoint", languages: tenLanguages, kind: .cloud),
    ]

    public static func named(_ id: String?) -> EngineInfo? {
        all.first { $0.id == id }
    }

    public var pythonVersion: String {
        if case .worker(let version) = kind { return version }
        return ""
    }

    public var isCloud: Bool { kind == .cloud }

    public var provider: CloudProvider? {
        switch id {
        case "elevenlabs": ElevenLabs()
        case "cartesia": Cartesia()
        default: nil
        }
    }

    /// The engine part of clip cache keys. Cloud engines include their model, and the custom
    /// endpoint its configuration, so changing either marks clips as out of date.
    @MainActor
    public var cacheName: String {
        if id == "custom" { return AppSettings.shared.customEndpoint.cacheName }
        if let provider { return "\(id)/\(provider.model)" }
        return id
    }

    /// The Keychain account holding this engine's API key.
    public var keychainAccount: String { "api-key.\(id)" }
}
