import Foundation
import Observation

/// Owns the speech backend for one project window and turns slides into cached clips.
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

    private var backend: SpeechBackend?
    private var cancelAll = false

    public init() {}

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var isBusy: Bool { !generating.isEmpty }

    public func start(engine: EngineInfo, device: String, settings: AppSettings) async {
        stop()
        if engine.isCloud {
            let key = Keychain.read(engine.keychainAccount)
            if engine.id != "custom", key?.isEmpty ?? true {
                state = .failed(CloudError.missingKey(engine.title).localizedDescription)
                return
            }
            backend = CloudBackend(engine: engine, key: key)
            state = .ready(engine: engine.id, device: "API")
            return
        }
        guard let uv = WorkerLaunch.findUV(preferred: settings.uvPath) else {
            state = .failed(LaunchError.uvNotFound.localizedDescription)
            return
        }
        let launch = WorkerLaunch.local(
            engine: engine, uv: uv, source: settings.packageSource,
            environmentsDirectory: AppSettings.supportDirectory.appending(path: "envs")
        )
        await startWorker(launch, engine: engine, device: device, startingMessage: "Preparing the Python environment. The first start downloads the engine and can take several minutes.")
    }

    func startWorker(_ launch: WorkerLaunch, engine: EngineInfo, device: String, startingMessage: String) async {
        let connection = WorkerConnection(executable: launch.executable, arguments: launch.arguments, environment: launch.environment)
        let worker = WorkerBackend(connection: connection)
        connection.onLog = { [weak self] line in
            Task { @MainActor in self?.receiveLog(line) }
        }
        connection.onExit = { [weak self, weak worker] error in
            Task { @MainActor in self?.workerExited(worker, error) }
        }
        backend = worker
        state = .starting(startingMessage)
        do {
            try connection.start()
            let hello = try await connection.request("hello")
            devices = hello["devices"] as? [String] ?? []
            state = .starting("Loading \(engine.title) on \(device)…")
            _ = try await connection.request("load", ["engine": engine.id, "device": device])
            state = .ready(engine: engine.id, device: device)
        } catch {
            if backend === worker {
                state = .failed(error.localizedDescription)
                worker.stop()
                backend = nil
            }
        }
    }

    public func stop() {
        backend?.stop()
        backend = nil
        generating.removeAll()
        state = .stopped
    }

    public func generate(_ slide: Slide, in project: Project) async {
        await run(slide, in: project)
        project.audioDidChange()
    }

    /// Slides whose audio is missing or out of date.
    public func staleSlides(in project: Project) -> [Slide] {
        guard let cache = project.clipCache() else { return [] }
        return project.slides.filter { !cache.isFresh($0) }
    }

    public func generateStale(in project: Project) async {
        isGeneratingAll = true
        cancelAll = false
        defer { isGeneratingAll = false }
        for slide in staleSlides(in: project) {
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
        guard let backend, isReady else {
            lastError = "Load a TTS engine first"
            return false
        }
        generating.insert(slide.num)
        defer { generating.remove(slide.num) }
        do {
            guard let voice = try project.preparedVoice() else {
                lastError = "Choose a voice sample first"
                return false
            }
            guard let cache = project.clipCache() else { return false }
            let language = project.settings.language
            let clip = slide.narration.isEmpty
                ? PCMClip(samples: [], sampleRate: AudioIO.voiceSampleRate)
                : try await backend.synthesize(slide.narration, language: language, voice: voice)
            try cache.store(slide, clip: clip)
            if !FileManager.default.fileExists(atPath: cache.ambientURL.path),
               let ambient = try await backend.ambient(language: language, voice: voice) {
                try cache.storeAmbient(ambient)
            }
            lastError = nil
            return true
        } catch {
            lastError = "Slide \(slide.num): \(error.localizedDescription)"
            return false
        }
    }

    private func receiveLog(_ line: String) {
        latestLog = line
        if case .starting = state, !line.isEmpty {
            state = .starting(line)
        }
    }

    private func workerExited(_ exited: WorkerBackend?, _ error: WorkerError) {
        guard let exited, exited === backend else { return }
        backend = nil
        state = .failed(error.localizedDescription)
    }
}
