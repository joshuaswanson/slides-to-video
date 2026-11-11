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
        #expect(Array(launch.arguments.prefix(11)) == [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3", "-p", "2222",
        ])
        #expect(launch.arguments[11] == "me@gpu.example.org")
        let command = launch.arguments[12]
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
