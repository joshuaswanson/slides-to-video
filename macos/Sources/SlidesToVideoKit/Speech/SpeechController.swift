import Foundation
import Observation

/// Owns the TTS worker for one project window and turns slides into cached clips.
@MainActor
@Observable
public final class SpeechController {
    public enum State: Equatable {
        case stopped
        case starting(String)
        case ready(engine: String, device: String)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public private(set) var devices: [String] = []
    public private(set) var generating: Set<Int> = []
    public private(set) var isGeneratingAll = false
    public private(set) var lastError: String?
    public private(set) var latestLog = ""

    private var connection: WorkerConnection?
    private var voiceHashOnWorker: String?
    private var cancelAll = false

    public init() {}

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var isBusy: Bool { !generating.isEmpty }

    public func start(engine: EngineInfo, device: String, settings: AppSettings) async {
        stop()
        guard let uv = WorkerLaunch.findUV(preferred: settings.uvPath) else {
            state = .failed(LaunchError.uvNotFound.localizedDescription)
            return
        }
        let launch = WorkerLaunch.local(
            engine: engine, uv: uv, source: settings.packageSource,
            environmentsDirectory: AppSettings.supportDirectory.appending(path: "envs")
        )
        let connection = WorkerConnection(executable: launch.executable, arguments: launch.arguments, environment: launch.environment)
        connection.onLog = { [weak self] line in
            Task { @MainActor in self?.receiveLog(line) }
        }
        connection.onExit = { [weak self, weak connection] error in
            Task { @MainActor in self?.workerExited(connection, error) }
        }
        self.connection = connection
        state = .starting("Preparing the Python environment. The first start downloads the engine and can take several minutes.")
        do {
            try connection.start()
            let hello = try await connection.request("hello")
            devices = hello["devices"] as? [String] ?? []
            state = .starting("Loading \(engine.title) on \(device)…")
            _ = try await connection.request("load", ["engine": engine.id, "device": device])
            state = .ready(engine: engine.id, device: device)
        } catch {
            if self.connection === connection {
                state = .failed(error.localizedDescription)
                connection.stop()
                self.connection = nil
            }
        }
    }

    public func stop() {
        connection?.onExit = nil
        connection?.stop()
        connection = nil
        voiceHashOnWorker = nil
        generating.removeAll()
        state = .stopped
    }

    public func generate(_ slide: Slide, in project: Project) async {
        await run(slide, in: project)
        project.audioDidChange()
    }

    public func generateStale(in project: Project) async {
        guard let cache = project.clipCache() else { return }
        isGeneratingAll = true
        cancelAll = false
        defer { isGeneratingAll = false }
        for slide in project.slides where !cache.isFresh(slide) {
            if cancelAll { break }
            let ok = await run(slide, in: project)
            project.audioDidChange()
            if !ok { break }
        }
    }

    public func cancelGenerateAll() {
        cancelAll = true
    }

    @discardableResult
    private func run(_ slide: Slide, in project: Project) async -> Bool {
        guard let connection, isReady else {
            lastError = "Start the voice engine first"
            return false
        }
        generating.insert(slide.num)
        defer { generating.remove(slide.num) }
        do {
            guard let voice = try project.preparedVoice() else {
                lastError = "Choose a voice sample first"
                return false
            }
            try await sendVoiceIfNeeded(voice, connection)
            guard let cache = project.clipCache() else { return false }
            let reply = try await connection.request("synthesize", ["text": slide.narration, "language": project.settings.language])
            try cache.store(slide, clip: try Self.clip(from: reply))
            if !FileManager.default.fileExists(atPath: cache.ambientURL.path) {
                let ambient = try await connection.request("ambient", ["language": project.settings.language])
                try cache.storeAmbient(try Self.clip(from: ambient))
            }
            lastError = nil
            return true
        } catch {
            lastError = "Slide \(slide.num): \(error.localizedDescription)"
            return false
        }
    }

    private func sendVoiceIfNeeded(_ voice: URL, _ connection: WorkerConnection) async throws {
        let hash = try Hashing.fileHash(voice)
        guard hash != voiceHashOnWorker else { return }
        _ = try await connection.request("set_voice", ["wav_b64": try Data(contentsOf: voice).base64EncodedString()])
        voiceHashOnWorker = hash
    }

    static func clip(from reply: WorkerConnection.Reply) throws -> PCMClip {
        guard let payload = reply["pcm16_b64"] as? String, let rate = reply["sample_rate"] as? Int else {
            throw WorkerError.malformedReply(String(describing: reply.keys.sorted()))
        }
        return try PCMClip(pcm16Base64: payload, sampleRate: rate)
    }

    private func receiveLog(_ line: String) {
        latestLog = line
        if case .starting = state, !line.isEmpty {
            state = .starting(line)
        }
    }

    private func workerExited(_ exited: WorkerConnection?, _ error: WorkerError) {
        guard let exited, exited === connection else { return }
        connection = nil
        voiceHashOnWorker = nil
        state = .failed(error.localizedDescription)
    }
}
