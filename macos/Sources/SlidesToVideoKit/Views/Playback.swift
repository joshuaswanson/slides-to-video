import AVFoundation
import SwiftUI

/// Plays the whole talk as one narration track and reports which slide is showing.
@MainActor
@Observable
final class TalkPlayer: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle, building, playing
    }

    private(set) var state: State = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    var onSlideChange: ((Int) -> Void)?

    private var track: NarrationTrack?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastIndex = -1

    var isActive: Bool { state != .idle }

    func toggle(_ project: Project) {
        if isActive { stop() } else { play(project) }
    }

    func play(_ project: Project) {
        stop()
        state = .building
        error = nil
        do {
            let track = try project.narrationTrack(clickURL: Resources.url("click", ext: "wav"))
            let url = project.cacheURL.appending(path: "preview_audio.wav")
            try AudioIO.writeWAV(track.samples, sampleRate: track.sampleRate, to: url)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.track = track
            self.player = player
            duration = track.duration
            lastIndex = -1
            player.play()
            state = .playing
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            self.error = error.localizedDescription
            state = .idle
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        track = nil
        state = .idle
        currentTime = 0
    }

    private func tick() {
        guard let player, let track else { return }
        currentTime = player.currentTime
        let index = track.slideIndex(at: currentTime)
        if index != lastIndex {
            lastIndex = index
            onSlideChange?(index)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Peak envelope of an audio file, cached per file and modification date.
enum Waveform {
    @MainActor private static var cache: [String: [Float]] = [:]

    @MainActor
    static func peaks(_ url: URL, buckets: Int = 240) -> [Float] {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(buckets)"
        if let hit = cache[key] { return hit }
        guard let samples = try? AudioIO.readMono(url, sampleRate: 8000), !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        let peaks = stride(from: 0, to: samples.count, by: size).map { start in
            samples[start..<min(start + size, samples.count)].reduce(0) { max($0, abs($1)) }
        }
        let top = max(peaks.max() ?? 1, 0.01)
        let normalized = peaks.map { $0 / top }
        cache[key] = normalized
        return normalized
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double?

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            for (i, peak) in peaks.enumerated() {
                let height = max(1.5, CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: max(1, step * 0.7), height: height)
                let played = progress.map { CGFloat(i) / CGFloat(peaks.count) <= $0 } ?? false
                context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(played ? .green : .green.opacity(0.55)))
            }
            if let progress {
                let x = size.width * progress
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
            }
        }
    }
}
