import Foundation
import Testing
@testable import SlidesToVideoKit

/// Serves canned responses and records requests, so no test reaches a real API.
final class MockAPI: URLProtocol, @unchecked Sendable {
    struct Recorded { let request: URLRequest; let body: Data }
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var recorded: [Recorded] = []
    static let lock = NSLock()

    static func session(_ handler: @escaping (URLRequest, Data) -> (Int, Data)) -> URLSession {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAPI.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let (status, data) = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: body))
            return Self.handler!(request, body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func pcm16(_ values: [Int16]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Suite(.serialized)
struct CloudTests {
    @Test func elevenLabsCloneAndSynthesize() async throws {
        let session = MockAPI.session { request, _ in
            if request.url!.path.hasSuffix("/voices/add") { return (200, json(["voice_id": "v123", "requires_verification": false])) }
            return (200, pcm16([0, 16384, -16384, 32767]))
        }
        let api = ElevenLabs(session: session)
        let id = try await api.cloneVoice(sample: Data("RIFF".utf8), name: "Me", language: "en", key: "k1")
        #expect(id == "v123")
        let clip = try await api.synthesize(text: "Hello", voiceID: id, language: "en", key: "k1")
        #expect(clip.sampleRate == 24000 && clip.samples.count == 4)
        #expect(abs(clip.samples[1] - 0.5) < 0.001)

        let clone = MockAPI.recorded[0], speak = MockAPI.recorded[1]
        #expect(clone.request.url!.absoluteString == "https://api.elevenlabs.io/v1/voices/add")
        #expect(clone.request.value(forHTTPHeaderField: "xi-api-key") == "k1")
        let multipart = String(decoding: clone.body, as: UTF8.self)
        #expect(multipart.contains("name=\"name\"\r\n\r\nMe") && multipart.contains("name=\"files\"; filename=\"voice.wav\""))
        #expect(speak.request.url!.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/v123?output_format=pcm_24000")
        let body = try JSONSerialization.jsonObject(with: speak.body) as! [String: String]
        #expect(body == ["text": "Hello", "model_id": "eleven_multilingual_v2"])
    }

    @Test func elevenLabsVerificationAndErrorsSurface() async throws {
        var session = MockAPI.session { _, _ in (200, json(["voice_id": "v", "requires_verification": true])) }
        await #expect(throws: CloudError.self) {
            _ = try await ElevenLabs(session: session).cloneVoice(sample: Data(), name: "n", language: "en", key: "k")
        }
        session = MockAPI.session { _, _ in (401, json(["detail": ["status": "invalid_api_key", "message": "Invalid API key"]])) }
        do {
            _ = try await ElevenLabs(session: session).synthesize(text: "x", voiceID: "v", language: "en", key: "bad")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "ElevenLabs returned 401: Invalid API key")
        }
    }

    @Test func cartesiaHeadersAndBody() async throws {
        let session = MockAPI.session { request, _ in
            request.url!.path.hasSuffix("/voices/clone") ? (200, json(["id": "c-9"])) : (200, pcm16([1000, -1000]))
        }
        let api = Cartesia(session: session)
        let id = try await api.cloneVoice(sample: Data("RIFF".utf8), name: "Me", language: "de", key: "sk_car_x")
        _ = try await api.synthesize(text: "Hallo", voiceID: id, language: "de", key: "sk_car_x")
        for call in MockAPI.recorded {
            #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_car_x")
            #expect(call.request.value(forHTTPHeaderField: "Cartesia-Version") == "2026-08-14")
        }
        let multipart = String(decoding: MockAPI.recorded[0].body, as: UTF8.self)
        #expect(multipart.contains("name=\"clip\"; filename=\"voice.wav\"") && multipart.contains("name=\"language\"\r\n\r\nde"))
        let body = try JSONSerialization.jsonObject(with: MockAPI.recorded[1].body) as! [String: Any]
        #expect(body["model_id"] as? String == "sonic-3.6" && body["transcript"] as? String == "Hallo")
        #expect((body["voice"] as? [String: String]) == ["id": "c-9"])
        let format = body["output_format"] as! [String: Any]
        #expect(format["container"] as? String == "raw" && format["encoding"] as? String == "pcm_s16le" && format["sample_rate"] as? Int == 24000)
    }

    @Test func customEndpointEscapesTemplateAndDecodesFormats() async throws {
        var endpoint = CustomEndpoint()
        endpoint.url = "https://tts.example.com/speak"
        endpoint.voiceID = "voice-1"
        endpoint.responseFormat = .pcm16
        endpoint.pcmSampleRate = 16000
        var session = MockAPI.session { _, _ in (200, pcm16([0, 0, 0])) }
        let clip = try await endpoint.synthesize(text: "He said \"hi\"\nthen left", language: "en", key: "secret", session: session)
        #expect(clip.sampleRate == 16000 && clip.samples.count == 3)
        let sent = try JSONSerialization.jsonObject(with: MockAPI.recorded[0].body) as! [String: String]
        #expect(sent == ["text": "He said \"hi\"\nthen left", "voice": "voice-1", "language": "en"])
        #expect(MockAPI.recorded[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")

        let wav = FileManager.default.temporaryDirectory.appending(path: "s2v-\(UUID().uuidString).wav")
        try AudioIO.writeWAV([Float](repeating: 0.1, count: 2400), sampleRate: 24000, to: wav)
        let wavData = try Data(contentsOf: wav)
        endpoint.responseFormat = .jsonBase64
        session = MockAPI.session { _, _ in (200, json(["audio_content": wavData.base64EncodedString()])) }
        let decoded = try await endpoint.synthesize(text: "x", language: "en", key: nil, session: session)
        #expect(decoded.samples.count == 2400)
        #expect(MockAPI.recorded[0].request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @MainActor
    @Test func backendClonesOnceAndInsertsPauses() async throws {
        let session = MockAPI.session { request, _ in
            request.url!.path.hasSuffix("/voices/add") ? (200, json(["voice_id": "v1"])) : (200, pcm16([Int16](repeating: 100, count: 2400)))
        }
        let defaults = UserDefaults(suiteName: "s2v-test-\(UUID().uuidString)")!
        let voice = Bundle.module.url(forResource: "voice", withExtension: "wav", subdirectory: "Fixtures")!
        let backend = CloudBackend(engine: EngineInfo.named("elevenlabs")!, key: "k", session: session, store: defaults)
        let clip = try await backend.synthesize("One. [pause 0.5] Two.", language: "en", voice: voice)
        #expect(clip.samples.count == 2400 + 12000 + 2400)
        _ = try await backend.synthesize("Three.", language: "en", voice: voice)
        let clones = MockAPI.recorded.filter { $0.request.url!.path.hasSuffix("/voices/add") }
        #expect(clones.count == 1)
        #expect(try await backend.ambient(language: "en", voice: voice) == nil)
    }

    @MainActor
    @Test func cacheNamesIncludeModelOrEndpoint() {
        #expect(EngineInfo.named("qwen3")!.cacheName == "qwen3")
        #expect(EngineInfo.named("elevenlabs")!.cacheName == "elevenlabs/eleven_multilingual_v2")
        #expect(EngineInfo.named("custom")!.cacheName.hasPrefix("custom:"))
    }
}
