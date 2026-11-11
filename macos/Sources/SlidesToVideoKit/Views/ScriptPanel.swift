import AVFoundation
import SwiftUI

@MainActor
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingURL: URL?
    private(set) var progress: Double = 0
    private(set) var elapsed: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playingURL == url { stop() } else { play(url, from: 0) }
    }

    func seek(_ url: URL, to fraction: Double) {
        if playingURL == url, let player {
            player.currentTime = fraction * player.duration
            update()
        } else {
            play(url, from: fraction)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingURL = nil
        progress = 0
        elapsed = 0
    }

    private func play(_ url: URL, from fraction: Double) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.currentTime = fraction * player.duration
        player.play()
        self.player = player
        playingURL = url
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        guard let player, player.duration > 0 else { return }
        elapsed = player.currentTime
        progress = player.currentTime / player.duration
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct ScriptPanel: View {
    let project: Project
    let slide: Slide
    let speech: SpeechController
    let player: ClipPlayer
    let toasts: Toasts
    @State private var draft: String
    @State private var status: SaveStatus = .idle
    @State private var pendingSave: Task<Void, Never>?

    enum SaveStatus: Equatable {
        case idle, unsaved, saved, failed
    }

    init(project: Project, slide: Slide, speech: SpeechController, player: ClipPlayer, toasts: Toasts) {
        self.project = project
        self.slide = slide
        self.speech = speech
        self.player = player
        self.toasts = toasts
        _draft = State(initialValue: slide.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.borderMuted)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(Theme.mono(13))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 12)
                if draft.isEmpty {
                    Text("Enter narration text for this slide...")
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            AudioSection(project: project, slide: slide, speech: speech, player: player, toasts: toasts, save: save)
            ProgressStrip(active: speech.generating.contains(slide.num) || speech.isGeneratingAll)
        }
        .background(Theme.bgSecondary)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.borderMuted).frame(width: 1) }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: slide.text) { _, newValue in
            if status != .unsaved { draft = newValue }
        }
        .onDisappear { save() }
        .onChange(of: speech.isBusy) { _, busy in
            if busy { save() }
        }
        .background {
            Button("Save", action: save).keyboardShortcut("s").hidden()
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                SectionLabel("Script", size: 12)
                Text("Slide \(slide.num)")
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(Theme.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.greenGlow, in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Group {
                switch status {
                case .idle: Text("")
                case .unsaved: Text("Unsaved").foregroundStyle(Theme.textMuted)
                case .saved: Text("Saved").foregroundStyle(Theme.greenDim)
                case .failed: Text("Save failed").foregroundStyle(Theme.red)
                }
            }
            .font(Theme.mono(11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func scheduleSave() {
        guard draft != slide.text else { return }
        status = .unsaved
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        guard status == .unsaved || status == .failed else { return }
        do {
            try project.updateText(slide: slide.num, text: draft)
            status = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if status == .saved { status = .idle }
            }
        } catch {
            status = .failed
            toasts.show("Failed to save slide \(slide.num): \(error.localizedDescription)", .error)
        }
    }
}

struct AudioSection: View {
    let project: Project
    let slide: Slide
    let speech: SpeechController
    let player: ClipPlayer
    let toasts: Toasts
    let save: () -> Void

    var body: some View {
        let _ = project.audioRevision
        let cache = project.clipCache()
        let fresh = cache?.isFresh(slide) ?? false
        let url = fresh ? cache?.clipURL(slide.num) : nil
        let duration = url.flatMap(AudioIO.duration)
        let isPlaying = url != nil && player.playingURL == url
        let isGenerating = speech.generating.contains(slide.num)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Audio")
                Spacer()
                Text(isPlaying ? format(player.elapsed) : duration.map(format) ?? "--:--")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.bgTertiary)
                if let url {
                    GeometryReader { geometry in
                        WaveformView(levels: Waveform.levels(url), progress: isPlaying ? player.progress : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                player.seek(url, to: min(max(location.x / geometry.size.width, 0), 1))
                            }
                    }
                } else {
                    Text(isGenerating ? "Generating..." : "No audio generated")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            HStack(spacing: 8) {
                PlayCircle(isPlaying: isPlaying) {
                    if let url { player.toggle(url) }
                }
                .disabled(url == nil)

                Button {
                    regenerate()
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            Spinner(size: 11, color: Theme.textSecondary)
                            Text("Generating...")
                        }
                    } else {
                        Label("Regenerate Audio", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.editor(.secondary, compact: true))
                .disabled(isGenerating || slide.narration.isEmpty)
                .keyboardShortcut("g", modifiers: .command)

                Button(action: save) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.editor(.ghost))
                .help("Save script")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderMuted).frame(height: 1) }
    }

    private func regenerate() {
        guard speech.isReady else {
            toasts.show("Load a TTS engine in Settings first", .error)
            return
        }
        save()
        player.stop()
        Task {
            await speech.generate(slide, in: project)
            if speech.lastError == nil { toasts.show("Audio generated for slide \(slide.num)", .success) }
        }
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%d:%02d.%d", Int(seconds) / 60, Int(seconds) % 60, Int((seconds.truncatingRemainder(dividingBy: 1)) * 10))
    }
}

struct PlayCircle: View {
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .background(hovering ? Theme.green : Theme.bgElevated, in: Circle())
                .overlay(Circle().strokeBorder(hovering ? Theme.green : Theme.borderSubtle))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && isEnabled }
    }
}

/// The editor's indeterminate 3 px progress bar under the script panel.
struct ProgressStrip: View {
    let active: Bool
    @State private var phase = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Theme.bgPrimary
                if active {
                    Capsule()
                        .fill(Theme.green)
                        .frame(width: geometry.size.width * 0.3)
                        .offset(x: phase ? geometry.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                        .onDisappear { phase = false }
                }
            }
        }
        .frame(height: active ? 3 : 0)
    }
}
