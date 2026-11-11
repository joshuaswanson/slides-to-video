import AVFoundation
import SwiftUI

@MainActor
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingURL: URL?
    private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playingURL = url
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingURL = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct AudioRow: View {
    let project: Project
    let slide: Slide
    let speech: SpeechController
    let player: ClipPlayer

    var body: some View {
        let _ = project.audioRevision
        let cache = project.clipCache()
        let url = cache?.clipURL(slide.num)
        let fresh = cache?.isFresh(slide) ?? false
        let isGenerating = speech.generating.contains(slide.num)

        VStack(spacing: 8) {
        if fresh, let url {
            WaveformView(peaks: Waveform.peaks(url), progress: player.playingURL == url ? player.progress : nil)
                .frame(height: 44)
        }
        HStack(spacing: 10) {
            Button {
                if let url { player.toggle(url) }
            } label: {
                Image(systemName: player.playingURL == url && url != nil ? "stop.fill" : "play.fill")
                    .frame(width: 18)
            }
            .disabled(!fresh)

            VStack(alignment: .leading, spacing: 2) {
                if isGenerating {
                    Text("Generating…")
                } else if fresh, let url, let duration = AudioIO.duration(url) {
                    Text(String(format: "%d:%04.1f", Int(duration) / 60, duration.truncatingRemainder(dividingBy: 60)))
                        .monospacedDigit()
                } else if slide.narration.isEmpty {
                    Text("No narration").foregroundStyle(.secondary)
                } else {
                    Text(cache == nil ? "Choose an engine" : "Needs audio").foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Spacer()

            Button {
                Task { await speech.generate(slide, in: project) }
            } label: {
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label(fresh ? "Regenerate" : "Generate", systemImage: "waveform")
                }
            }
            .disabled(!speech.isReady || isGenerating || slide.narration.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
        }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
