import Foundation

/// Something that turns narration into audio in a cloned voice.
@MainActor
protocol SpeechBackend: AnyObject {
    func synthesize(_ text: String, language: String, voice: URL) async throws -> PCMClip
    /// A loop of the engine's background noise for pauses, or nil to use silence.
    func ambient(language: String, voice: URL) async throws -> PCMClip?
    func stop()
}

/// The Python worker, started locally or through ssh.
@MainActor
final class WorkerBackend: SpeechBackend {
    let connection: WorkerConnection
    private var voiceHashOnWorker: String?

    init(connection: WorkerConnection) {
        self.connection = connection
    }

    func synthesize(_ text: String, language: String, voice: URL) async throws -> PCMClip {
        try await sendVoiceIfNeeded(voice)
        return try Self.clip(from: try await connection.request("synthesize", ["text": text, "language": language]))
    }

    func ambient(language: String, voice: URL) async throws -> PCMClip? {
        try await sendVoiceIfNeeded(voice)
        return try Self.clip(from: try await connection.request("ambient", ["language": language]))
    }

    func stop() {
        connection.onExit = nil
        connection.stop()
    }

    private func sendVoiceIfNeeded(_ voice: URL) async throws {
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
}

/// A hosted API. The voice sample is cloned once per provider, sample, and language, and the
/// resulting voice ID is remembered in the app's defaults.
@MainActor
final class CloudBackend: SpeechBackend {
    let engine: EngineInfo
    let key: String?
    let session: URLSession
    let store: UserDefaults

    init(engine: EngineInfo, key: String?, session: URLSession = .shared, store: UserDefaults = .standard) {
        self.engine = engine
        self.key = key
        self.session = session
        self.store = store
    }

    func synthesize(_ text: String, language: String, voice: URL) async throws -> PCMClip {
        let rate = AudioIO.voiceSampleRate
        var samples: [Float] = []
        for item in Script.splitPauses(text) {
            switch item {
            case .pause(let seconds):
                samples += [Float](repeating: 0, count: Int((seconds * Double(rate)).rounded()))
            case .speech(let speech):
                let clip = try await speak(speech, language: language, voice: voice)
                samples += clip.sampleRate == rate ? clip.samples : try resample(clip, to: rate)
            }
        }
        return PCMClip(samples: samples, sampleRate: rate)
    }

    func ambient(language: String, voice: URL) async throws -> PCMClip? { nil }

    func stop() {}

    private func speak(_ text: String, language: String, voice: URL) async throws -> PCMClip {
        if engine.id == "custom" {
            return try await AppSettings.shared.customEndpoint.synthesize(text: text, language: language, key: key, session: session)
        }
        guard let provider = providerWithSession, let key else { throw CloudError.missingKey(engine.title) }
        let voiceID = try await clonedVoice(provider, voice: voice, language: language, key: key)
        return try await provider.synthesize(text: text, voiceID: voiceID, language: language, key: key)
    }

    private var providerWithSession: CloudProvider? {
        switch engine.id {
        case "elevenlabs": ElevenLabs(session: session)
        case "cartesia": Cartesia(session: session)
        default: nil
        }
    }

    func clonedVoice(_ provider: CloudProvider, voice: URL, language: String, key: String) async throws -> String {
        let storeKey = "clonedVoice.\(provider.id).\(try Hashing.fileHash(voice)).\(language)"
        if let existing = store.string(forKey: storeKey) { return existing }
        let id = try await provider.cloneVoice(sample: try Data(contentsOf: voice), name: "Slides to Video voice", language: language, key: key)
        store.set(id, forKey: storeKey)
        return id
    }

    private func resample(_ clip: PCMClip, to rate: Int) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "s2v-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try AudioIO.writeWAV(clip.samples, sampleRate: clip.sampleRate, to: file)
        return try AudioIO.readMono(file, sampleRate: rate)
    }
}
