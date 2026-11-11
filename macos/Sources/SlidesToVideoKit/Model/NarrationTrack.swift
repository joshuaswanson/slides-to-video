import AVFoundation
import Foundation

/// Mirrors `slides_to_video.audio.NarrationTrack`: one audio track for the whole talk.
/// Each slide occupies [pause][narration][pause], and the click straddles each slide boundary.
public struct NarrationTrack: Sendable {
    public static let clickSplit = 0.085

    public var samples: [Float]
    public var sampleRate: Int
    public var slideStarts: [Double]
    public var narrationSpans: [(start: Double, end: Double)]

    public var duration: Double { Double(samples.count) / Double(sampleRate) }

    public var slideDurations: [Double] {
        zip(slideStarts, slideStarts.dropFirst() + [duration]).map { $1 - $0 }
    }

    /// The index of the slide showing at `time`.
    public func slideIndex(at time: Double) -> Int {
        max(0, (slideStarts.lastIndex { $0 <= time }) ?? 0)
    }

    public static func build(
        clips: [[Float]], sampleRate: Int, pause: Double,
        ambient: [Float]? = nil, click: [Float]? = nil, clickSplit: Double = clickSplit
    ) -> NarrationTrack {
        let gap = tile(ambient, count: Int((pause * Double(sampleRate)).rounded()))
        var samples: [Float] = []
        var starts: [Int] = []
        var spans: [(Int, Int)] = []
        for clip in clips {
            starts.append(samples.count)
            let narrationStart = samples.count + gap.count
            spans.append((narrationStart, narrationStart + clip.count))
            samples += gap
            samples += clip
            samples += gap
        }
        if let click, !click.isEmpty {
            let split = Int((clickSplit * Double(sampleRate)).rounded())
            for boundary in starts.dropFirst() {
                let at = boundary - split
                let lo = max(at, 0), hi = min(at + click.count, samples.count)
                guard lo < hi else { continue }
                for i in lo..<hi { samples[i] += click[i - at] }
            }
        }
        for i in samples.indices { samples[i] = min(1, max(-1, samples[i])) }
        let rate = Double(sampleRate)
        return NarrationTrack(
            samples: samples,
            sampleRate: sampleRate,
            slideStarts: starts.map { Double($0) / rate },
            narrationSpans: spans.map { (Double($0.0) / rate, Double($0.1) / rate) }
        )
    }

    static func tile(_ loop: [Float]?, count: Int) -> [Float] {
        guard let loop, !loop.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { loop[$0 % loop.count] }
    }
}

public enum TrackError: LocalizedError {
    case missingAudio([Int])
    case noSlides

    public var errorDescription: String? {
        switch self {
        case .missingAudio(let slides):
            "Slides \(slides.map(String.init).joined(separator: ", ")) need audio. Generate them first."
        case .noSlides: "The script has no slides"
        }
    }
}

extension Project {
    /// Builds the narration track from cached clips. Slides without narration become pauses only.
    public func narrationTrack(clickURL: URL?) throws -> NarrationTrack {
        guard let cache = clipCache() else { throw TrackError.missingAudio(slides.map(\.num)) }
        guard !slides.isEmpty else { throw TrackError.noSlides }
        let missing = slides.filter { !$0.narration.isEmpty && !cache.isFresh($0) }.map(\.num)
        guard missing.isEmpty else { throw TrackError.missingAudio(missing) }

        let firstClip = slides.first { !$0.narration.isEmpty }.map { cache.clipURL($0.num) }
        let sampleRate = firstClip.flatMap { try? AVAudioFile(forReading: $0) }.map { Int($0.fileFormat.sampleRate) }
            ?? AudioIO.voiceSampleRate
        let speed = settings.speed
        let clips = try slides.map { slide -> [Float] in
            guard !slide.narration.isEmpty else { return [] }
            let samples = try AudioIO.readMono(cache.clipURL(slide.num), sampleRate: sampleRate)
            return speed == 1 ? samples : try TimeStretch.apply(samples, sampleRate: sampleRate, rate: speed)
        }
        let ambient = FileManager.default.fileExists(atPath: cache.ambientURL.path)
            ? try AudioIO.readMono(cache.ambientURL, sampleRate: sampleRate) : nil
        let click = try settings.useClick ? clickURL.map { try AudioIO.readMono($0, sampleRate: sampleRate) } : nil
        return NarrationTrack.build(clips: clips, sampleRate: sampleRate, pause: settings.pause, ambient: ambient, click: click)
    }
}

/// Changes tempo without changing pitch, like ffmpeg's atempo filter in the CLI.
public enum TimeStretch {
    public static func apply(_ samples: [Float], sampleRate: Int, rate: Double) throws -> [Float] {
        guard !samples.isEmpty, rate != 1 else { return samples }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(input, at: nil)
        player.play()

        let expected = Int((Double(samples.count) / rate).rounded())
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var result: [Float] = []
        result.reserveCapacity(expected)
        while result.count < expected {
            let frames = min(AVAudioFrameCount(expected - result.count), output.frameCapacity)
            let status = try engine.renderOffline(frames, to: output)
            guard status == .success else { break }
            result += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        }
        player.stop()
        engine.stop()
        return result
    }
}
