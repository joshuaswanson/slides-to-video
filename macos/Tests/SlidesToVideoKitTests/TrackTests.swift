import Foundation
import Testing
@testable import SlidesToVideoKit

struct TrackTests {
    struct Case: Decodable {
        let clips: [[Float]], sample_rate: Int, pause: Double
        let ambient: [Float]?, click: [Float]?, split: Double
        let samples: [Float], slide_starts: [Double], narration_spans: [[Double]]
    }

    let cases: [Case] = {
        struct Wrapper: Decodable { let tracks: [Case] }
        let url = Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Wrapper.self, from: Data(contentsOf: url)).tracks
    }()

    @Test func layoutMatchesFixture() {
        for c in cases {
            let track = NarrationTrack.build(
                clips: c.clips, sampleRate: c.sample_rate, pause: c.pause,
                ambient: c.ambient, click: c.click, clickSplit: c.split
            )
            #expect(track.samples.count == c.samples.count)
            #expect(zip(track.samples, c.samples).allSatisfy { abs($0 - $1) < 1e-5 })
            #expect(track.slideStarts.count == c.slide_starts.count)
            #expect(zip(track.slideStarts, c.slide_starts).allSatisfy { abs($0 - $1) < 1e-9 })
            #expect(zip(track.narrationSpans, c.narration_spans).allSatisfy {
                abs($0.start - $1[0]) < 1e-9 && abs($0.end - $1[1]) < 1e-9
            })
        }
    }

    @Test func slideIndexFollowsStarts() {
        let track = NarrationTrack.build(clips: [[Float](repeating: 0, count: 100), [Float](repeating: 0, count: 50)], sampleRate: 1000, pause: 0.03)
        #expect(track.slideIndex(at: 0) == 0)
        #expect(track.slideIndex(at: 0.159) == 0)
        #expect(track.slideIndex(at: 0.16) == 1)
        #expect(track.slideIndex(at: 99) == 1)
        #expect(track.slideDurations.map { ($0 * 1000).rounded() } == [160, 110])
    }

    @Test func timeStretchChangesLengthKeepsPitch() throws {
        let sr = 24000
        let tone = (0..<sr).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / Double(sr))) }
        let fast = try TimeStretch.apply(tone, sampleRate: sr, rate: 1.25)
        #expect(abs(Double(fast.count) - Double(sr) / 1.25) < 2)
        func crossings(_ x: ArraySlice<Float>) -> Int { zip(x, x.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count }
        let middle = fast[4000..<16000]
        let hz = Double(crossings(middle)) / (Double(middle.count) / Double(sr))
        #expect(abs(hz - 440) < 15)
    }
}

@MainActor
struct ProjectTrackTests {
    func makeProject() throws -> Project {
        let folder = FileManager.default.temporaryDirectory.appending(path: "s2v-track-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Slide 1\n\nOne.\n\n---\n\n## Slide 2\n\n---\n\n## Slide 3\n\nThree.\n".write(
            to: folder.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let project = try Project.open(folder: folder)
        let voice = Bundle.module.url(forResource: "voice", withExtension: "wav", subdirectory: "Fixtures")!
        try project.setVoice(voice)
        project.settings.engine = "qwen3"
        return project
    }

    @Test func reportsMissingAudioThenBuilds() throws {
        let project = try makeProject()
        #expect(throws: TrackError.self) { try project.narrationTrack(clickURL: nil) }
        let cache = try #require(project.clipCache())
        for slide in project.slides where !slide.narration.isEmpty {
            try cache.store(slide, clip: PCMClip(samples: [Float](repeating: 0.2, count: 24000), sampleRate: 24000))
        }
        project.settings.pause = 0.5
        project.settings.useClick = false
        let track = try project.narrationTrack(clickURL: nil)
        #expect(track.sampleRate == 24000)
        #expect(abs(track.duration - (1 + 0 + 1 + 6 * 0.5)) < 1e-6)
        #expect(track.slideStarts.map { ($0 * 10).rounded() / 10 } == [0, 2, 3])
    }

    @Test func speedShortensNarrationOnly() throws {
        let project = try makeProject()
        let cache = try #require(project.clipCache())
        for slide in project.slides where !slide.narration.isEmpty {
            try cache.store(slide, clip: PCMClip(samples: [Float](repeating: 0.2, count: 24000), sampleRate: 24000))
        }
        project.settings.pause = 0.5
        project.settings.speed = 2
        let click = Bundle.module.url(forResource: "voice", withExtension: "wav", subdirectory: "Fixtures")!
        let track = try project.narrationTrack(clickURL: click)
        #expect(abs(track.duration - (0.5 + 0.5 + 3)) < 0.01)
    }
}
