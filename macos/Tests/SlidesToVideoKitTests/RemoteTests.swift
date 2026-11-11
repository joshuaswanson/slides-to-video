import Foundation
import Testing
@testable import SlidesToVideoKit

struct RemoteLaunchTests {
    @Test func sshArgumentsAndDefaultCommand() {
        var host = RemoteHost()
        host.destination = "me@gpu.example.org"
        host.port = "2222"
        host.cudaDevices = "0,1"
        let launch = WorkerLaunch.remote(engine: EngineInfo.named("qwen3")!, host: host)
        #expect(launch.executable.path == "/usr/bin/ssh")
        #expect(Array(launch.arguments.prefix(9)) == [
            "-T", "-o", "ConnectTimeout=30", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3", "-p", "2222",
        ])
        #expect(!launch.arguments.contains("BatchMode=yes"))
        #expect(launch.arguments[9] == "me@gpu.example.org")
        let command = launch.arguments[10]
        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains("export CUDA_VISIBLE_DEVICES="))
        #expect(command.contains("archive/refs/tags/v\(WorkerLaunch.packageVersion).tar.gz"))
        #expect(command.contains("--extra qwen3 --python 3.12 slides-to-video-worker"))
        #expect(!launch.arguments.contains { $0.contains("ControlMaster") || $0.contains("Reconnect") })
    }

    @Test func customCommandAndQuoting() {
        var host = RemoteHost()
        host.destination = "lab"
        host.command = "cd ~/s2v && uv run --extra chatterbox slides-to-video-worker"
        host.cudaDevices = "4,5"
        #expect(WorkerLaunch.remoteCommand(engine: EngineInfo.named("chatterbox")!, host: host)
            == "export CUDA_VISIBLE_DEVICES='4,5'; cd ~/s2v && uv run --extra chatterbox slides-to-video-worker")
        #expect(WorkerLaunch.shellQuote("it's") == "'it'\\''s'")
        host.cudaDevices = ""
        host.port = nil
        let launch = WorkerLaunch.remote(engine: EngineInfo.named("qwen3")!, host: host)
        #expect(!launch.arguments.contains("-p"))
    }
}

@MainActor
struct RemoteSessionTests {
    static let fakeWorker = """
    import json, sys
    for line in sys.stdin:
        req = json.loads(line)
        cmd = req["cmd"]
        if cmd == "hello":
            reply = {"devices": ["cuda:0", "cpu"]}
        elif cmd == "load":
            reply = {"engine": req["engine"]}
        elif cmd == "die":
            sys.exit(9)
        else:
            reply = {}
        print(json.dumps({"id": req["id"], "ok": True, **reply}), flush=True)
    """

    /// Stands in for /usr/bin/ssh: ignores the options and host, runs the remote command locally,
    /// and counts how often it was launched.
    func fakeSSH(in dir: URL) throws -> (URL, URL) {
        let counter = dir.appending(path: "launches")
        let script = dir.appending(path: "ssh")
        try "#!/bin/bash\necho x >> \(counter.path)\nexec bash -c \"${@: -1}\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, counter)
    }

    @Test func connectsThroughSshAndStaysDownAfterExit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "s2v-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let worker = dir.appending(path: "worker.py")
        try Self.fakeWorker.write(to: worker, atomically: true, encoding: .utf8)
        let (ssh, counter) = try fakeSSH(in: dir)

        var host = RemoteHost()
        host.destination = "fake-host"
        host.command = "/usr/bin/python3 \(worker.path)"
        let engine = EngineInfo.named("qwen3")!
        let speech = SpeechController()
        await speech.startWorker(WorkerLaunch.remote(engine: engine, host: host, ssh: ssh), engine: engine, device: "cuda:0", startingMessage: "")
        #expect(speech.state == .ready(engine: "qwen3", device: "cuda:0"))
        #expect(speech.devices == ["cuda:0", "cpu"])

        let backend = try #require(Mirror(reflecting: speech).descendant("_backend") as? WorkerBackend)
        await #expect(throws: WorkerError.self) { _ = try await backend.connection.request("die") }
        try await Task.sleep(for: .milliseconds(500))
        guard case .failed = speech.state else {
            Issue.record("expected failed state, got \(speech.state)")
            return
        }
        try await Task.sleep(for: .seconds(1))
        let launches = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        #expect(launches == 1)
    }
}


/// The built app binary, which doubles as the askpass helper.
let appBinary: URL? = {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build/debug/SlidesToVideo")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

struct AskpassTests {
    @Test func promptRoundTripAndCancel() throws {
        let server = try AskpassServer { prompt, reply in reply(prompt == "Password:" ? "s3cret" : nil) }
        defer { server.stop() }
        #expect(Askpass.request("Password:", socketPath: server.socketPath) == "s3cret")
        #expect(Askpass.request("Other:", socketPath: server.socketPath) == nil)
        let env = server.environment(askpass: URL(filePath: "/x/app"))
        #expect(env["SSH_ASKPASS"] == "/x/app" && env["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @Test(.enabled(if: appBinary != nil)) func appBinaryActsAsHelper() throws {
        let server = try AskpassServer { prompt, reply in reply("answer to \(prompt)") }
        defer { server.stop() }
        let process = Process()
        process.executableURL = appBinary
        process.arguments = ["jdoe@host's password:"]
        process.environment = ["S2V_ASKPASS_SOCKET": server.socketPath]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "answer to jdoe@host's password:\n")
    }
}

@MainActor
struct PasswordSessionTests {
    /// Asks for a password through SSH_ASKPASS like ssh does, then runs the remote command.
    func fakeSSH(in dir: URL) throws -> (URL, URL) {
        let counter = dir.appending(path: "launches")
        let script = dir.appending(path: "ssh")
        try """
        #!/bin/bash
        echo x >> \(counter.path)
        answer=$("$SSH_ASKPASS" "jdoe@fake-host's password:") || exit 255
        [ "$answer" = "hunter2" ] || { echo "Permission denied" >&2; exit 255; }
        exec bash -c "${@: -1}"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, counter)
    }

    func connect(answer: String, binary: URL) async throws -> (SpeechController, Int, String?) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "s2v-pw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let worker = dir.appending(path: "worker.py")
        try RemoteSessionTests.fakeWorker.write(to: worker, atomically: true, encoding: .utf8)
        let (ssh, counter) = try fakeSSH(in: dir)
        var host = RemoteHost()
        host.destination = "fake-host"
        host.command = "/usr/bin/python3 \(worker.path)"

        let speech = SpeechController()
        let server = try AskpassServer { text, reply in
            Task { @MainActor in speech.testSetPrompt(text, reply) }
        }
        defer { server.stop() }
        let engine = EngineInfo.named("qwen3")!
        let launch = WorkerLaunch.remote(engine: engine, host: host, ssh: ssh, promptEnvironment: server.environment(askpass: binary))
        let start = Task { await speech.startWorker(launch, engine: engine, device: "cuda:0", startingMessage: "") }
        var seen: String?
        for _ in 0..<100 where seen == nil {
            try await Task.sleep(for: .milliseconds(50))
            if let prompt = speech.prompt {
                seen = prompt.text
                speech.answerPrompt(answer)
            }
        }
        await start.value
        try await Task.sleep(for: .milliseconds(300))
        let launches = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        return (speech, launches, seen)
    }

    @Test(.enabled(if: appBinary != nil)) func correctPasswordConnects() async throws {
        let (speech, launches, prompt) = try await connect(answer: "hunter2", binary: appBinary!)
        #expect(prompt == "jdoe@fake-host's password:")
        #expect(speech.state == .ready(engine: "qwen3", device: "cuda:0"))
        #expect(launches == 1)
        speech.stop()
    }

    @Test(.enabled(if: appBinary != nil)) func wrongPasswordFailsWithoutRetrying() async throws {
        let (speech, launches, _) = try await connect(answer: "nope", binary: appBinary!)
        guard case .failed = speech.state else {
            Issue.record("expected failure, got \(speech.state)")
            return
        }
        #expect(launches == 1)
    }
}
