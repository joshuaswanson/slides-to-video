import PDFKit
import SwiftUI

struct ProjectView: View {
    @Bindable var project: Project
    let model: AppModel
    @State private var selection: Int?
    @State private var speech = SpeechController()
    @State private var clipPlayer = ClipPlayer()
    @State private var talk = TalkPlayer()
    @State private var toasts = Toasts()

    private var selectedSlide: Slide? {
        project.slides.first { $0.num == selection } ?? project.slides.first
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(project: project, model: model, speech: speech, talk: talk, toasts: toasts, beforePlay: clipPlayer.stop)
            if let error = project.scriptError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.red.opacity(0.2))
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    PreviewPanel(project: project, slide: selectedSlide, chooseSlides: chooseSlides)
                    if let slide = selectedSlide {
                        ScriptPanel(project: project, slide: slide, speech: speech, player: clipPlayer, toasts: toasts)
                            .id(slide.num)
                            .frame(width: max(340, geometry.size.width * 0.4))
                    }
                }
            }
            TimelinePanel(project: project, selection: selectedSlide?.num) { num in
                talk.stop()
                selection = num
            }
        }
        .background(Theme.bgPrimary)
        .overlay(alignment: .bottom) { ToastOverlay(toasts: toasts) }
        .onAppear {
            talk.onSlideChange = { index in
                if project.slides.indices.contains(index) { selection = project.slides[index].num }
            }
        }
        .onChange(of: talk.error) { _, error in
            if let error { toasts.show(error, .error) }
        }
        .onChange(of: speech.lastError) { _, error in
            if let error { toasts.show(error, .error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            project.reloadScript()
        }
        .onDisappear {
            speech.stop()
            clipPlayer.stop()
            talk.stop()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    private func chooseSlides() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try project.setSlides(url)
            toasts.show("Loaded \(project.pdf?.pageCount ?? 0) slides", .success)
        } catch {
            toasts.show(error.localizedDescription, .error)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let current = selectedSlide,
              let index = project.slides.firstIndex(of: current) else { return .ignored }
        let next = index + delta
        guard project.slides.indices.contains(next) else { return .handled }
        talk.stop()
        selection = project.slides[next].num
        return .handled
    }
}

struct TopBar: View {
    let project: Project
    let model: AppModel
    let speech: SpeechController
    let talk: TalkPlayer
    let toasts: Toasts
    let beforePlay: () -> Void
    @State private var showSettings = false

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Color.clear.frame(width: 64, height: 1)
                Wordmark(size: 16)
                Rectangle().fill(Theme.borderSubtle).frame(width: 1, height: 20)
                Text(project.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 280)
                Button {
                    toasts.show("Video export is not built yet")
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.editor(.primary))
                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.editor(.secondary))
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPanel(project: project, speech: speech, toasts: toasts)
                }
            }
            HStack(spacing: 8) {
                generateAllButton
                playAllButton
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.bgSecondary)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderMuted).frame(height: 1) }
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private var generateAllButton: some View {
        if speech.isGeneratingAll {
            Button {
                speech.cancelGenerateAll()
            } label: {
                HStack(spacing: 6) {
                    Spinner(size: 12, color: Theme.blue)
                    Text("Generating…")
                }
            }
            .buttonStyle(.editor(.generateAll))
            .help("Stop after the current slide")
        } else {
            Button {
                guard speech.isReady else {
                    toasts.show("Load a TTS engine in Settings first", .error)
                    return
                }
                Task {
                    await speech.generateStale(in: project)
                    if speech.lastError == nil { toasts.show("All audio generated", .success) }
                }
            } label: {
                Label("Generate All Audio", systemImage: "play.fill")
            }
            .buttonStyle(.editor(.generateAll))
            .disabled(speech.isBusy)
        }
    }

    private var playAllButton: some View {
        Button {
            beforePlay()
            talk.toggle(project)
        } label: {
            switch talk.state {
            case .idle: Label("Play All", systemImage: "play.fill")
            case .building: Label("Building…", systemImage: "stop.fill")
            case .playing: Label("Stop", systemImage: "stop.fill")
            }
        }
        .buttonStyle(.editor(.light))
        .keyboardShortcut(.return, modifiers: .command)
    }
}

struct PreviewPanel: View {
    let project: Project
    let slide: Slide?
    let chooseSlides: () -> Void

    var body: some View {
        ZStack {
            Theme.bgPrimary
            if let slide, let page = project.page(for: slide) {
                SlideCard(page: page, number: slide.num)
            } else {
                Placeholder(text: project.pdf == nil ? "Click to load a slides PDF" : "No PDF page for slide \(slide?.num ?? 0)", action: chooseSlides)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    struct SlideCard: View {
        let page: PDFPage
        let number: Int

        var body: some View {
            GeometryReader { geometry in
                let width = min(geometry.size.width, 720, geometry.size.height * 16 / 9)
                let size = CGSize(width: width, height: width * 9 / 16)
                ZStack(alignment: .topLeading) {
                    Theme.bgSlide
                    Image(nsImage: page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                    Text("Slide \(number)")
                        .font(Theme.mono(11, .medium))
                        .tracking(0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .padding(12)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .padding(24)
        }
    }

    struct Placeholder: View {
        let text: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.system(size: 34, weight: .light))
                        .opacity(0.4)
                    Text(text).font(Theme.ui(14))
                }
                .foregroundStyle(hovering ? Theme.textSecondary : Theme.textMuted)
                .frame(maxWidth: 720)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLarge)
                        .strokeBorder(hovering ? Theme.green : Theme.borderSubtle, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(24)
        }
    }
}
