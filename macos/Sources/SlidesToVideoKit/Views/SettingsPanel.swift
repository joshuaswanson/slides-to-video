import SwiftUI
import UniformTypeIdentifiers

struct SettingsPanel: View {
    @Bindable var project: Project
    let speech: SpeechController
    let toasts: Toasts
    @Bindable var settings = AppSettings.shared

    private static let languages: [(String, String)] = [
        ("en", "English"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("fr", "French"),
        ("de", "German"), ("es", "Spanish"), ("ar", "Arabic"), ("ru", "Russian"), ("pt", "Portuguese"),
    ]

    private var engine: EngineInfo? { EngineInfo.named(project.settings.engine) }

    private var devices: [String] {
        let known = speech.devices.isEmpty ? ["mps", "cpu"] : speech.devices
        return known.contains(settings.localDevice) ? known : [settings.localDevice] + known
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Configuration", size: 12)
                .padding(.bottom, 12)

            row("TTS Engine") {
                FieldMenu(
                    title: engine?.title ?? "Select engine...",
                    options: EngineInfo.all.map { ($0.id, $0.title) },
                    selection: project.settings.engine
                ) { id in
                    guard id != project.settings.engine else { return }
                    speech.stop()
                    project.settings.engine = id
                    project.audioDidChange()
                }
            }
            row("Device") {
                FieldMenu(title: settings.localDevice, options: devices.map { ($0, $0) }, selection: settings.localDevice) {
                    settings.localDevice = $0
                }
            }
            engineButton
                .padding(.bottom, 14)
            row("Language") {
                FieldMenu(
                    title: Self.languages.first { $0.0 == project.settings.language }?.1 ?? project.settings.language,
                    options: Self.languages,
                    selection: project.settings.language
                ) { code in
                    if let engine, !engine.languages.contains(code) {
                        toasts.show("\(engine.title) only supports English", .error)
                        return
                    }
                    project.settings.language = code
                    project.audioDidChange()
                }
            }
            HStack(spacing: 10) {
                row("Pause (s)") { NumberField(value: $project.settings.pause, range: 0...10, step: 0.1) }
                row("Speed") { NumberField(value: $project.settings.speed, range: 0.5...3, step: 0.05) }
            }
            Toggle(isOn: $project.settings.useClick) {
                Text("Click sound on slide transitions")
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .tint(Theme.green)
            .padding(.bottom, 14)
            row("Voice Sample") {
                UploadButton(title: project.settings.voiceFile ?? "Choose audio file...", uploaded: project.settings.voiceFile != nil) {
                    pick([.audio]) { url in
                        try project.setVoice(url)
                        toasts.show("Voice sample ready", .success)
                    }
                }
            }
            row("Slides PDF") {
                UploadButton(title: project.settings.slidesFile ?? "Choose PDF...", uploaded: project.pdf != nil) {
                    pick([.pdf]) { url in
                        try project.setSlides(url)
                        toasts.show("Loaded \(project.pdf?.pageCount ?? 0) slides", .success)
                    }
                }
            }
            status
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.bgSecondary)
        .presentationBackground(Theme.bgSecondary)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var engineButton: some View {
        switch speech.state {
        case .ready:
            Button("Stop Engine") { speech.stop() }
                .buttonStyle(.editor(.secondary))
                .frame(maxWidth: .infinity)
        case .starting:
            Button {
                speech.stop()
            } label: {
                HStack(spacing: 6) {
                    Spinner(size: 12, color: .white)
                    Text("Loading… click to cancel")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.editor(.primary))
        default:
            Button {
                guard let engine else {
                    toasts.show("Select a TTS engine first", .error)
                    return
                }
                toasts.show("Loading \(engine.title) engine...")
                Task {
                    await speech.start(engine: engine, device: settings.localDevice, settings: settings)
                    if speech.isReady { toasts.show("Engine \(engine.title) loaded on \(settings.localDevice)", .success) }
                }
            } label: {
                Text("Load Engine").frame(maxWidth: .infinity)
            }
            .buttonStyle(.editor(.primary))
        }
    }

    @ViewBuilder
    private var status: some View {
        let text: String = switch speech.state {
        case .stopped: engine == nil ? "No engine selected." : "Engine \(engine!.title) selected, not loaded."
        case .starting(let detail): detail
        case .ready(let id, let device): "Engine \(EngineInfo.named(id)?.title ?? id) loaded on \(device)."
        case .failed(let message): message
        }
        Text(text + "  Script: \(project.scriptURL.path)")
            .font(Theme.ui(11))
            .foregroundStyle(speech.state.isFailure ? Theme.red : Theme.textMuted)
            .lineLimit(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(.bottom, 14)
    }

    private func pick(_ types: [UTType], apply: (URL) throws -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try apply(url) } catch { toasts.show(error.localizedDescription, .error) }
    }
}

extension SpeechController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A select field styled like the editor's dropdowns.
struct FieldMenu: View {
    let title: String
    let options: [(String, String)]
    let selection: String?
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Toggle(option.1, isOn: Binding(get: { option.0 == selection }, set: { _ in choose(option.0) }))
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.ui(13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderSubtle))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .font(Theme.ui(13))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(focused ? Theme.green : Theme.borderSubtle))
    }
}

/// The editor's dashed upload button, solid green once a file is chosen.
struct UploadButton: View {
    let title: String
    let uploaded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(uploaded ? Theme.green : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(
                        uploaded ? Theme.greenDim : (hovering ? Theme.green : Theme.borderSubtle),
                        style: StrokeStyle(lineWidth: 1, dash: uploaded ? [] : [4, 3])
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
