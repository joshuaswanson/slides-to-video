import Foundation

public struct RemoteHost: Codable, Equatable, Sendable {
    /// Anything ssh accepts: user@host, or an alias from ~/.ssh/config.
    public var destination = ""
    public var port: String?
    public var cudaDevices = ""
    /// Replaces the default uvx command, for example to run a checkout on the server.
    public var command = ""

    public init() {}
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
    /// Must equal the version in pyproject.toml. Each app build installs the worker from the
    /// matching release tag, so later pushes to the repository cannot change what it runs.
    public static let packageVersion = "0.4.0"

    /// The package spec uv installs the worker from: a local checkout, or a git URL pinned to
    /// `v<packageVersion>` unless the URL already names a ref after `@`.
    public static func requirement(source: String, engine: EngineInfo) -> String {
        if isLocalPath(source) {
            return "slides-to-video[\(engine.id)] @ \(URL(filePath: source).absoluteString)"
        }
        let pinned = source.dropFirst("https://".count).contains("@") ? source : "\(source)@v\(packageVersion)"
        return "slides-to-video[\(engine.id)] @ git+\(pinned)"
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

    /// One ssh process that runs the worker on a remote host. BatchMode stops ssh from asking
    /// for a password it cannot get. Keep-alives make a dropped link end the process, and
    /// nothing restarts it.
    public static func remote(engine: EngineInfo, host: RemoteHost, ssh: URL = URL(filePath: "/usr/bin/ssh")) -> WorkerLaunch {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
        if let port = host.port, !port.isEmpty { arguments += ["-p", port] }
        arguments += [host.destination, remoteCommand(engine: engine, host: host)]
        return WorkerLaunch(executable: ssh, arguments: arguments, environment: ProcessInfo.processInfo.environment)
    }

    public static func remoteCommand(engine: EngineInfo, host: RemoteHost) -> String {
        let devices = host.cudaDevices.trimmingCharacters(in: .whitespaces)
        let environment = devices.isEmpty ? "" : "CUDA_VISIBLE_DEVICES=\(shellQuote(devices)) "
        let custom = host.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return environment + custom }
        let requirement = requirement(source: repository, engine: engine)
        return "PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$PATH\" \(environment)exec uvx --python \(engine.pythonVersion) --from \(shellQuote(requirement)) slides-to-video-worker"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
