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

/// Mean absolute level per bucket, normalized to the loudest bucket, cached per file version.
enum Waveform {
    @MainActor private static var cache: [String: [Float]] = [:]

    @MainActor
    static func levels(_ url: URL, buckets: Int = 600) -> [Float] {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(buckets)"
        if let hit = cache[key] { return hit }
        guard let samples = try? AudioIO.readMono(url, sampleRate: 8000), !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        let levels = stride(from: 0, to: samples.count, by: size).map { start in
            let chunk = samples[start..<min(start + size, samples.count)]
            return chunk.reduce(0) { $0 + abs($1) } / Float(chunk.count)
        }
        let top = max(levels.max() ?? 1, 0.001)
        let normalized = levels.map { $0 / top }
        cache[key] = normalized
        return normalized
    }
}

/// Bars like the editor's canvas: 2 px wide, 1 px apart, centered, green gradient.
struct WaveformView: View {
    let levels: [Float]
    let progress: Double?

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let barWidth: CGFloat = 2, gap: CGFloat = 1
            let count = max(1, Int(size.width / (barWidth + gap)))
            let gradient = Gradient(stops: [
                .init(color: Theme.green.opacity(0.7), location: 0),
                .init(color: Theme.green.opacity(0.9), location: 0.5),
                .init(color: Theme.green.opacity(0.7), location: 1),
            ])
            for i in 0..<count {
                let lo = i * levels.count / count
                let hi = max(lo + 1, (i + 1) * levels.count / count)
                let level = levels[lo..<min(hi, levels.count)].reduce(0, +) / Float(hi - lo)
                let height = max(2, CGFloat(level) * size.height * 0.85)
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(rect), with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
            if let progress {
                let x = size.width * progress
                var glow = context
                glow.addFilter(.shadow(color: Theme.green.opacity(0.5), radius: 3))
                glow.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.green))
            }
        }
    }
}
