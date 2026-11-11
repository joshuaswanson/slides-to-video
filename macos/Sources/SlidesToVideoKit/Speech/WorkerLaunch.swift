import Foundation

public struct EngineInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let languages: Set<String>
    public let pythonVersion: String

    public static let all = [
        EngineInfo(id: "qwen3", title: "Qwen3-TTS", languages: ["en", "zh", "ja", "ko", "fr", "de", "es", "ar", "ru", "pt"], pythonVersion: "3.12"),
        EngineInfo(id: "chatterbox", title: "Chatterbox", languages: ["en"], pythonVersion: "3.11"),
    ]

    public static func named(_ id: String?) -> EngineInfo? {
        all.first { $0.id == id }
    }
}

public enum LaunchError: LocalizedError {
    case uvNotFound

    public var errorDescription: String? {
        switch self {
        case .uvNotFound: "uv was not found. Install it from https://docs.astral.sh/uv/ or set its path in Settings."
        }
    }
}

public struct WorkerLaunch: Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]

    public static let repository = "https://github.com/joshuaswanson/slides-to-video"

    /// The package spec uv installs the worker from: a local checkout or the public repository.
    public static func requirement(source: String, engine: EngineInfo) -> String {
        isLocalPath(source)
            ? "slides-to-video[\(engine.id)] @ \(URL(filePath: source).absoluteString)"
            : "slides-to-video[\(engine.id)] @ git+\(source)"
    }

    static func isLocalPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix("~")
    }

    /// The default source: the checkout this build came from, else the public repository.
    public static func defaultSource(executable: URL? = Bundle.main.executableURL) -> String {
        let path = executable?.path ?? ""
        if let range = path.range(of: "/macos/.build/") {
            return String(path[..<range.lowerBound])
        }
        return repository
    }

    public static func local(engine: EngineInfo, uv: URL, source: String, environmentsDirectory: URL) -> WorkerLaunch {
        var environment = baseEnvironment(uv: uv)
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        let arguments: [String]
        if isLocalPath(source) {
            environment["UV_PROJECT_ENVIRONMENT"] = environmentsDirectory.appending(path: engine.id).path
            arguments = [
                "run", "--project", (source as NSString).expandingTildeInPath, "--extra", engine.id,
                "--no-dev", "--python", engine.pythonVersion, "slides-to-video-worker",
            ]
        } else {
            arguments = [
                "tool", "run", "--python", engine.pythonVersion,
                "--from", requirement(source: source, engine: engine), "slides-to-video-worker",
            ]
        }
        return WorkerLaunch(executable: uv, arguments: arguments, environment: environment)
    }

    static func baseEnvironment(uv: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [uv.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    public static func findUV(preferred: String?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [preferred, "\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
        return candidates
            .compactMap { $0.map { ($0 as NSString).expandingTildeInPath } }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }
}
