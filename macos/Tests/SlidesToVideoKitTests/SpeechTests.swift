import Foundation
import Testing
@testable import SlidesToVideoKit

struct ClipCacheTests {
    struct Expected: Decodable {
        let engine: String, language: String, voice_hash: String
        let settings_key: String, slide_text: String, slide_key: String, ambient_name: String
    }

    let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    func expected() throws -> Expected {
        struct Wrapper: Decodable { let clip_cache: Expected }
        let data = try Data(contentsOf: fixtures.appending(path: "parity.json"))
        return try JSONDecoder().decode(Wrapper.self, from: data).clip_cache
    }

    @Test func keysMatchPython() throws {
        let want = try expected()
        let voice = fixtures.appending(path: "voice.wav")
        #expect(try Hashing.fileHash(voice) == want.voice_hash)
        let cache = ClipCache(directory: URL(filePath: "/nonexistent"), engineName: want.engine, language: want.language, voiceURL: voice)
        #expect(cache.settingsKey == want.settings_key)
        #expect(cache.key(Slide(num: 3, text: want.slide_text)) == want.slide_key)
        #expect(cache.ambientURL.lastPathComponent == want.ambient_name)
    }

    @Test func storeMarksFreshAndTextChangeMarksStale() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = fixtures.appending(path: "voice.wav")
        let cache = ClipCache(directory: dir, engineName: "qwen3", language: "en", voiceURL: voice)
        let slide = Slide(num: 2, text: "Hello there")
        #expect(!cache.isFresh(slide))
        try cache.store(slide, clip: PCMClip(samples: [Float](repeating: 0.1, count: 2400), sampleRate: 24000))
        #expect(cache.isFresh(slide))
        #expect(!cache.isFresh(Slide(num: 2, text: "Changed")))
        #expect(!ClipCache(directory: dir, engineName: "chatterbox", language: "en", voiceURL: voice).isFresh(slide))
        #expect(abs((AudioIO.duration(cache.clipURL(2)) ?? 0) - 0.1) < 0.001)
    }

    @Test func legacyEntriesAreAdopted() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slide = Slide(num: 1, text: "Old take")
        try AudioIO.writeWAV([0, 0, 0], sampleRate: 24000, to: dir.appending(path: "slide_01.wav"))
        let legacy = Hashing.legacyTextHash(slide.narration)
        try JSONSerialization.data(withJSONObject: ["slide_01": legacy]).write(to: dir.appending(path: "hashes.json"))
        let cache = ClipCache(directory: dir, engineName: "qwen3", language: "en", voiceURL: fixtures.appending(path: "voice.wav"))
        #expect(cache.isFresh(slide))
        #expect(cache.manifest()["slide_01"] == cache.key(slide))
    }
}

struct WorkerConnectionTests {
    static let fakeWorker = """
    import json, sys
    for line in sys.stdin:
        req = json.loads(line)
        print("noise on stderr", file=sys.stderr, flush=True)
        if req["cmd"] == "echo":
            reply = {"id": req["id"], "ok": True, "value": req["value"]}
        elif req["cmd"] == "quit":
            sys.exit(3)
        else:
            reply = {"id": req["id"], "ok": False, "error": "bad command"}
        print(json.dumps(reply), flush=True)
    """

    func connection() throws -> WorkerConnection {
        let c = WorkerConnection(executable: URL(filePath: "/usr/bin/python3"), arguments: ["-c", Self.fakeWorker], environment: [:])
        try c.start()
        return c
    }

    @Test func requestsRoundTripConcurrently() async throws {
        let c = try connection()
        defer { c.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let reply = try await c.request("echo", ["value": i])
                    #expect(reply["value"] as? Int == i)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func errorRepliesThrow() async throws {
        let c = try connection()
        defer { c.stop() }
        await #expect(throws: WorkerError.self) { _ = try await c.request("nope") }
        #expect(try await c.request("echo", ["value": "still alive"])["value"] as? String == "still alive")
    }

    @Test func exitFailsPendingRequestsAndDoesNotRestart() async throws {
        let c = try connection()
        await #expect(throws: WorkerError.self) { _ = try await c.request("quit") }
        await #expect(throws: WorkerError.self) { _ = try await c.request("echo", ["value": 1]) }
        #expect(!c.isRunning)
    }
}

struct WorkerLaunchTests {
    @Test func defaultSourceIsCheckoutDuringDevelopment() {
        #expect(WorkerLaunch.defaultSource(executable: URL(filePath: "/x/repo/macos/.build/debug/SlidesToVideo")) == "/x/repo")
        #expect(WorkerLaunch.defaultSource(executable: URL(filePath: "/Applications/Slides to Video.app/Contents/MacOS/x")) == WorkerLaunch.repository)
    }

    @Test func gitSourceUsesUvToolRun() {
        let engine = EngineInfo.named("chatterbox")!
        let launch = WorkerLaunch.local(engine: engine, uv: URL(filePath: "/u/uv"), source: WorkerLaunch.repository, environmentsDirectory: URL(filePath: "/e"))
        #expect(launch.arguments == [
            "tool", "run", "--python", "3.11",
            "--from", "slides-to-video[chatterbox] @ git+https://github.com/joshuaswanson/slides-to-video@v\(WorkerLaunch.packageVersion)",
            "slides-to-video-worker",
        ])
    }

    @Test func explicitRefIsKept() {
        let engine = EngineInfo.named("qwen3")!
        #expect(WorkerLaunch.requirement(source: "https://github.com/me/fork@main", engine: engine)
            == "slides-to-video[qwen3] @ git+https://github.com/me/fork@main")
    }

    @Test func packageVersionMatchesPyproject() throws {
        let pyproject = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "pyproject.toml")
        let text = try String(contentsOf: pyproject, encoding: .utf8)
        #expect(text.contains("version = \"\(WorkerLaunch.packageVersion)\""))
    }

    @Test func checkoutSourceUsesPerEngineEnvironment() {
        let engine = EngineInfo.named("qwen3")!
        let launch = WorkerLaunch.local(engine: engine, uv: URL(filePath: "/u/uv"), source: "/repo", environmentsDirectory: URL(filePath: "/e"))
        #expect(launch.arguments.prefix(5) == ["run", "--project", "/repo", "--extra", "qwen3"])
        #expect(launch.environment["UV_PROJECT_ENVIRONMENT"] == "/e/qwen3")
    }
}
