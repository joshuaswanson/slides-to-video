import Foundation

public enum CloudError: LocalizedError {
    case missingKey(String)
    case http(provider: String, status: Int, message: String)
    case badResponse(String)
    case needsVerification(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "Add your \(provider) API key in Settings"
        case .http(let provider, let status, let message): "\(provider) returned \(status): \(message)"
        case .badResponse(let detail): detail
        case .needsVerification(let provider): "\(provider) requires verifying this voice in your account before it can be used"
        }
    }
}

/// A hosted TTS service that clones a voice from a sample and synthesizes speech with it.
public protocol CloudProvider: Sendable {
    var id: String { get }
    var title: String { get }
    /// Identifies the model in cache keys, so changing models regenerates audio.
    var model: String { get }
    var languages: Set<String> { get }
    func cloneVoice(sample: Data, name: String, language: String, key: String) async throws -> String
    func synthesize(text: String, voiceID: String, language: String, key: String) async throws -> PCMClip
    func deleteVoice(_ voiceID: String, key: String) async throws
}

struct HTTP {
    let session: URLSession

    func send(_ request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse("\(provider) sent no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.http(provider: provider, status: http.statusCode, message: Self.message(from: data))
        }
        return data
    }

    /// Pulls a readable message out of the error bodies these APIs return.
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
            if let detail = object["detail"] as? [[String: Any]] {
                return detail.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
            if let detail = object["detail"] as? String { return detail }
            for key in ["message", "error", "title"] {
                if let message = object[key] as? String { return message }
            }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

struct Multipart {
    let boundary = "s2v-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

public struct ElevenLabs: CloudProvider {
    public let id = "elevenlabs"
    public let title = "ElevenLabs"
    public let model = "eleven_multilingual_v2"
    public let languages: Set<String> = ["en", "zh", "ja", "ko", "fr", "de", "es", "ar", "ru", "pt"]
    let base: URL
    let http: HTTP

    public init(base: URL = URL(string: "https://api.elevenlabs.io")!, session: URLSession = .shared) {
        self.base = base
        http = HTTP(session: session)
    }

    public func cloneVoice(sample: Data, name: String, language: String, key: String) async throws -> String {
        var form = Multipart()
        form.field("name", name)
        form.file("files", filename: "voice.wav", mimeType: "audio/wav", data: sample)
        var request = URLRequest(url: base.appending(path: "v1/voices/add"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        let data = try await http.send(request, provider: title)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voiceID = object["voice_id"] as? String else {
            throw CloudError.badResponse("ElevenLabs did not return a voice_id")
        }
        if object["requires_verification"] as? Bool == true { throw CloudError.needsVerification(title) }
        return voiceID
    }

    public func synthesize(text: String, voiceID: String, language: String, key: String) async throws -> PCMClip {
        var components = URLComponents(url: base.appending(path: "v1/text-to-speech/\(voiceID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
        let data = try await http.send(request, provider: title)
        return PCMClip(pcm16: data, sampleRate: 24000)
    }

    public func deleteVoice(_ voiceID: String, key: String) async throws {
        var request = URLRequest(url: base.appending(path: "v1/voices/\(voiceID)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        _ = try await http.send(request, provider: title)
    }
}

public struct Cartesia: CloudProvider {
    public static let apiVersion = "2026-08-14"
    public let id = "cartesia"
    public let title = "Cartesia"
    public let model = "sonic-3.6"
    public let languages: Set<String> = ["en", "zh", "ja", "ko", "fr", "de", "es", "ar", "ru", "pt"]
    let base: URL
    let http: HTTP

    public init(base: URL = URL(string: "https://api.cartesia.ai")!, session: URLSession = .shared) {
        self.base = base
        http = HTTP(session: session)
    }

    private func request(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        return request
    }

    public func cloneVoice(sample: Data, name: String, language: String, key: String) async throws -> String {
        var form = Multipart()
        form.file("clip", filename: "voice.wav", mimeType: "audio/wav", data: sample)
        form.field("name", name)
        form.field("language", language)
        var request = request("voices/clone", key: key)
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        let data = try await http.send(request, provider: title)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let voiceID = object["id"] as? String else {
            throw CloudError.badResponse("Cartesia did not return a voice id")
        }
        return voiceID
    }

    public func synthesize(text: String, voiceID: String, language: String, key: String) async throws -> PCMClip {
        var request = request("tts/bytes", key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model_id": model,
            "transcript": text,
            "voice": ["id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 24000],
            "language": language,
        ] as [String: Any])
        let data = try await http.send(request, provider: title)
        return PCMClip(pcm16: data, sampleRate: 24000)
    }

    public func deleteVoice(_ voiceID: String, key: String) async throws {
        var request = request("voices/\(voiceID)", key: key)
        request.httpMethod = "DELETE"
        _ = try await http.send(request, provider: title)
    }
}

/// A user-configured HTTP endpoint for any other TTS service or a self-hosted server.
public struct CustomEndpoint: Codable, Equatable, Sendable {
    public enum ResponseFormat: String, Codable, CaseIterable, Sendable {
        case audioFile = "Audio file (WAV, MP3, …)"
        case pcm16 = "Raw 16-bit PCM"
        case jsonBase64 = "JSON with base64 audio"
    }

    public var url = ""
    public var authHeader = "Authorization"
    public var authPrefix = "Bearer "
    public var bodyTemplate = #"{"text": "{{text}}", "voice": "{{voice_id}}", "language": "{{language}}"}"#
    public var voiceID = ""
    public var responseFormat = ResponseFormat.audioFile
    public var pcmSampleRate = 24000
    public var jsonField = "audio_content"

    public init() {}

    public var cacheName: String {
        "custom:" + Hashing.textHash(url, bodyTemplate, voiceID, responseFormat.rawValue)
    }

    /// Fills the template, escaping each value for a JSON string context.
    func body(text: String, language: String) -> Data {
        func escaped(_ value: String) -> String {
            let quoted = String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            return String(quoted.dropFirst(2).dropLast(2))
        }
        let filled = bodyTemplate
            .replacingOccurrences(of: "{{text}}", with: escaped(text))
            .replacingOccurrences(of: "{{language}}", with: escaped(language))
            .replacingOccurrences(of: "{{voice_id}}", with: escaped(voiceID))
        return Data(filled.utf8)
    }

    public func synthesize(text: String, language: String, key: String?, session: URLSession = .shared) async throws -> PCMClip {
        guard let endpoint = URL(string: url), endpoint.scheme?.hasPrefix("http") == true else {
            throw CloudError.badResponse("Set the custom endpoint URL in Settings")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty, !authHeader.isEmpty {
            request.setValue(authPrefix + key, forHTTPHeaderField: authHeader)
        }
        request.httpBody = body(text: text, language: language)
        let data = try await HTTP(session: session).send(request, provider: "Custom endpoint")
        switch responseFormat {
        case .pcm16:
            return PCMClip(pcm16: data, sampleRate: pcmSampleRate)
        case .audioFile:
            return try Self.decode(data)
        case .jsonBase64:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encoded = object[jsonField] as? String, let audio = Data(base64Encoded: encoded) else {
                throw CloudError.badResponse("The response has no base64 field \"\(jsonField)\"")
            }
            return try Self.decode(audio)
        }
    }

    static func decode(_ audio: Data) throws -> PCMClip {
        let file = FileManager.default.temporaryDirectory.appending(path: "s2v-\(UUID().uuidString).audio")
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return PCMClip(samples: try AudioIO.readMono(file, sampleRate: AudioIO.voiceSampleRate), sampleRate: AudioIO.voiceSampleRate)
    }
}

extension PCMClip {
    init(pcm16 data: Data, sampleRate: Int) {
        let samples = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
        self.init(samples: samples, sampleRate: sampleRate)
    }
}
