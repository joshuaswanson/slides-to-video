import Foundation
import Testing
@testable import SlidesToVideoKit

/// Runs the real Python worker. Opt in with S2V_INTEGRATION=1 and set S2V_VOICE to a voice sample.
@MainActor
struct IntegrationTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["S2V_INTEGRATION"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(30)))
    func generatesSlideWithLocalWorker() async throws {
        let env = ProcessInfo.processInfo.environment
        let engine = EngineInfo.named(env["S2V_ENGINE"] ?? "chatterbox")!
        let folder = FileManager.default.temporaryDirectory.appending(path: "s2v-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Slide 1\n\nHello from the Mac app. [pause 0.3] This is a test.\n".write(
            to: folder.appending(path: "script.md"), atomically: true, encoding: .utf8)

        let project = try Project.open(folder: folder)
        try project.setVoice(URL(filePath: try #require(env["S2V_VOICE"])))
        project.settings.engine = engine.id

        let settings = AppSettings.shared
        let checkout = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        settings.packageSource = checkout.path
        let speech = SpeechController()
        await speech.start(engine: engine, device: env["S2V_DEVICE"] ?? "mps", settings: settings)
        #expect(speech.isReady, "\(speech.state)")
        defer { speech.stop() }

        let slide = try #require(project.slides.first)
        await speech.generate(slide, in: project)
        #expect(speech.lastError == nil, "\(speech.lastError ?? "")")
        let cache = try #require(project.clipCache())
        #expect(cache.isFresh(slide))
        let duration = try #require(AudioIO.duration(cache.clipURL(1)))
        #expect(duration > 1.5)
        #expect(FileManager.default.fileExists(atPath: cache.ambientURL.path))
        print("integration: \(engine.id) clip \(String(format: "%.1f", duration))s at \(cache.clipURL(1).path)")
    }
}
