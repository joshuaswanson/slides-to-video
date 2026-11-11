import Foundation

public struct RemoteHost: Codable, Equatable, Sendable {
    /// Anything ssh accepts: user@host, or an alias from ~/.ssh/config.
    public var destination = ""
    public var port: String?
    public var cudaDevices = ""
    /// Replaces the default command, for example to run a checkout on the server.
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
    /// Must equal the version in pyproject.toml. Each app build runs the worker from the
    /// matching release tag, so later pushes to the repository cannot change what it runs.
    public static let packageVersion = "1.0.0"

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

    /// A GitHub repository URL, optionally followed by `@ref`. Without a ref, the app's release tag.
    static func archive(source: String) -> (url: String, ref: String) {
        let parts = source.split(separator: "@", maxSplits: 1).map(String.init)
        let repo = parts[0].hasSuffix("/") ? String(parts[0].dropLast()) : parts[0]
        let ref = parts.count > 1 ? parts[1] : "v\(packageVersion)"
        let isTag = ref.hasPrefix("v") && ref.dropFirst().first?.isNumber == true
        let path = isTag ? "archive/refs/tags/\(ref).tar.gz" : "archive/\(ref).tar.gz"
        return ("\(repo)/\(path)", ref)
    }

    /// A shell script that unpacks the source archive once and runs the worker with
    /// `uv run --frozen`, so it gets exactly the dependency versions in the release's uv.lock.
    /// `base` and `uv` are shell expressions; one environment is kept per release and engine.
    static func bootstrapScript(engine: EngineInfo, source: String, base: String, uv: String) -> String {
        let (url, ref) = archive(source: source)
        let slug = ref.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }
        let name = String(slug)
        return """
        set -e
        base=\(base)
        src="$base/source/\(name)"
        if [ ! -f "$src/uv.lock" ]; then
          echo "Downloading slides-to-video \(ref)" >&2
          tmp="$(mktemp -d)"
          curl -fsSL \(shellQuote(url)) | tar xz -C "$tmp" --strip-components 1
          mkdir -p "$base/source"
          rm -rf "$src"
          mv "$tmp" "$src"
        fi
        export UV_PROJECT_ENVIRONMENT="$base/envs/\(name)-\(engine.id)"
        exec \(uv) run --frozen --no-dev --project "$src" --extra \(engine.id) --python \(engine.pythonVersion) slides-to-video-worker
        """
    }

    public static func local(engine: EngineInfo, uv: URL, source: String, environmentsDirectory: URL) -> WorkerLaunch {
        var environment = baseEnvironment(uv: uv)
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        if isLocalPath(source) {
            environment["UV_PROJECT_ENVIRONMENT"] = environmentsDirectory.appending(path: engine.id).path
            let arguments = [
                "run", "--project", (source as NSString).expandingTildeInPath, "--extra", engine.id,
                "--no-dev", "--python", engine.pythonVersion, "slides-to-video-worker",
            ]
            return WorkerLaunch(executable: uv, arguments: arguments, environment: environment)
        }
        let base = environmentsDirectory.deletingLastPathComponent().path
        let script = bootstrapScript(engine: engine, source: source, base: shellQuote(base), uv: shellQuote(uv.path))
        return WorkerLaunch(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], environment: environment)
    }

    /// One ssh process that runs the worker on a remote host. Prompts for passwords and codes go
    /// through `promptEnvironment` (see Askpass). Keep-alives make a dropped link end the process,
    /// and nothing restarts it.
    public static func remote(
        engine: EngineInfo, host: RemoteHost, ssh: URL = URL(filePath: "/usr/bin/ssh"),
        promptEnvironment: [String: String] = [:]
    ) -> WorkerLaunch {
        var arguments = [
            "-T",
            "-o", "ConnectTimeout=30",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
        if let port = host.port, !port.isEmpty { arguments += ["-p", port] }
        arguments += [host.destination, remoteCommand(engine: engine, host: host)]
        let environment = ProcessInfo.processInfo.environment.merging(promptEnvironment) { $1 }
        return WorkerLaunch(executable: ssh, arguments: arguments, environment: environment)
    }

    public static func remoteCommand(engine: EngineInfo, host: RemoteHost) -> String {
        let devices = host.cudaDevices.trimmingCharacters(in: .whitespaces)
        let environment = devices.isEmpty ? "" : "export CUDA_VISIBLE_DEVICES=\(shellQuote(devices)); "
        let custom = host.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return environment + custom }
        let script = bootstrapScript(engine: engine, source: repository, base: "\"$HOME/.cache/slides-to-video\"", uv: "uv")
        let body = "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$PATH\"; \(environment)\(script)"
        return "sh -c \(shellQuote(body))"
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
