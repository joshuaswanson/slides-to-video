import AppKit
import AVFoundation
import PDFKit
import Testing
@testable import SlidesToVideoKit

struct ExportTests {
    func page(_ color: NSColor) -> PDFPage {
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return PDFPage(image: image)!
    }

    func averageRed(_ image: CGImage) -> Double {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(context.data!.load(as: UInt8.self)) / 255
    }

    @Test func exportsVideoWithSlideChangesAtTrackBoundaries() async throws {
        let sr = 24000
        let tone = (0..<sr).map { Float(0.2 * sin(Double($0) * 0.05)) }
        let track = NarrationTrack.build(clips: [tone, Array(tone.prefix(sr / 2))], sampleRate: sr, pause: 0.5)
        let frames = VideoExporter.renderFrames(pages: [page(.red), page(.blue)], height: 360)
        #expect(frames.first?.width == 640 && frames.first?.height == 360)

        let url = FileManager.default.temporaryDirectory.appending(path: "s2v-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await VideoExporter.export(track: track, frames: frames, to: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - track.duration) < 0.1, "duration \(duration) vs \(track.duration)")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await videoTracks.first!.load(.naturalSize)
        #expect(size == CGSize(width: 640, height: 360))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let boundary = track.slideStarts[1]
        let before = try await generator.image(at: CMTime(seconds: boundary - 0.1, preferredTimescale: 600)).image
        let after = try await generator.image(at: CMTime(seconds: boundary + 0.1, preferredTimescale: 600)).image
        #expect(averageRed(before) > 0.8)
        #expect(averageRed(after) < 0.2)
    }

    @Test func cancellationStopsExportAndRemovesFile() async throws {
        let track = NarrationTrack.build(clips: [[Float](repeating: 0, count: 24000 * 20)], sampleRate: 24000, pause: 0.5)
        let frames = VideoExporter.renderFrames(pages: [page(.green)], height: 360)
        let url = FileManager.default.temporaryDirectory.appending(path: "s2v-cancel-\(UUID().uuidString).mp4")
        await #expect(throws: ExportError.self) {
            try await VideoExporter.export(track: track, frames: frames, to: url, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func subtitlesFollowNarrationSpans() {
        let slides = [Slide(num: 1, text: "One [pause] two"), Slide(num: 2, text: ""), Slide(num: 3, text: "Three")]
        let track = NarrationTrack.build(clips: [[Float](repeating: 0, count: 2000), [], [Float](repeating: 0, count: 1000)], sampleRate: 1000, pause: 1)
        #expect(Subtitles.srt(slides: slides, track: track) ==
            "1\n00:00:01,000 --> 00:00:03,000\nOne two\n\n2\n00:00:07,000 --> 00:00:08,000\nThree\n")
        #expect(Subtitles.timestamp(59.9996) == "00:01:00,000")
        #expect(Subtitles.timestamp(3723.0456) == "01:02:03,046")
    }

    @Test func oldSettingsFilesStillDecode() throws {
        let json = #"{"engine":"qwen3","language":"de","pause":2,"speed":1,"useClick":false}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        #expect(settings.language == "de" && settings.pause == 2 && !settings.useClick)
        #expect(settings.videoHeight == 1080 && settings.exportSubtitles)
    }
}
