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
        ScrollView {
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
            if let engine, engine.isCloud {
                APIKeyRow(engine: engine, toasts: toasts)
                if engine.id == "custom" {
                    CustomEndpointFields(endpoint: $settings.customEndpoint)
                }
            } else {
                row("Device") {
                    FieldMenu(title: settings.localDevice, options: devices.map { ($0, $0) }, selection: settings.localDevice) {
                        settings.localDevice = $0
                    }
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
            checkbox("Click sound on slide transitions", isOn: $project.settings.useClick)
            row("Video Height") {
                FieldMenu(
                    title: "\(project.settings.videoHeight)p",
                    options: [720, 1080, 1440, 2160].map { ("\($0)", "\($0)p") },
                    selection: "\(project.settings.videoHeight)"
                ) { project.settings.videoHeight = Int($0) ?? 1080 }
            }
            checkbox("Save subtitles (.srt) next to the video", isOn: $project.settings.exportSubtitles)
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
            Rectangle().fill(Theme.borderMuted).frame(height: 1).padding(.vertical, 12)
            HStack(spacing: 16) {
                FooterLink(title: "Report an Issue", systemImage: "exclamationmark.bubble", url: AppLinks.issues)
                FooterLink(title: "Buy Me a Coffee", systemImage: "cup.and.saucer", url: AppLinks.coffee)
            }
        }
        .padding(16)
        }
        .frame(width: 320)
        .frame(maxHeight: 720)
        .background(Theme.bgSecondary)
        .presentationBackground(Theme.bgSecondary)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var engineButton: some View {
        switch speech.state {
        case .ready:
            Button(engine?.isCloud == true ? "Disconnect" : "Stop Engine") { speech.stop() }
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
                if !engine.isCloud { toasts.show("Loading \(engine.title) engine...") }
                Task {
                    await speech.start(engine: engine, device: settings.localDevice, settings: settings)
                    if speech.isReady {
                        toasts.show(engine.isCloud ? "Connected to \(engine.title)" : "Engine \(engine.title) loaded on \(settings.localDevice)", .success)
                    }
                }
            } label: {
                Text(engine?.isCloud == true ? "Connect" : "Load Engine").frame(maxWidth: .infinity)
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

    private func checkbox(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .toggleStyle(.checkbox)
        .tint(Theme.green)
        .padding(.bottom, 14)
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

/// Saves an API key to the Keychain. The stored key is never shown again, only whether one exists.
struct APIKeyRow: View {
    let engine: EngineInfo
    let toasts: Toasts
    @State private var draft = ""
    @State private var hasKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("API Key").font(Theme.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                SecureField(hasKey ? "Saved in Keychain" : (engine.id == "custom" ? "Optional" : "Paste your key"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(hasKey ? Theme.greenDim : Theme.borderSubtle))
                    .onSubmit(save)
                if !draft.isEmpty {
                    Button("Save", action: save).buttonStyle(.editor(.secondary, compact: true))
                } else if hasKey {
                    Button("Remove") {
                        Keychain.delete(engine.keychainAccount)
                        hasKey = false
                    }
                    .buttonStyle(.editor(.ghost, compact: true))
                }
            }
            Text("Generated audio is billed to this key.").font(Theme.ui(11)).foregroundStyle(Theme.textMuted)
        }
        .padding(.bottom, 14)
        .onAppear { hasKey = Keychain.read(engine.keychainAccount) != nil }
        .onChange(of: engine) { _, engine in
            draft = ""
            hasKey = Keychain.read(engine.keychainAccount) != nil
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.save(key, for: engine.keychainAccount)
            draft = ""
            hasKey = true
            toasts.show("\(engine.title) key saved in the Keychain", .success)
        } catch {
            toasts.show(error.localizedDescription, .error)
        }
    }
}

struct CustomEndpointFields: View {
    @Binding var endpoint: CustomEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("URL", text: $endpoint.url, prompt: "https://example.com/tts")
            HStack(spacing: 8) {
                field("Auth header", text: $endpoint.authHeader, prompt: "Authorization")
                field("Key prefix", text: $endpoint.authPrefix, prompt: "Bearer ")
            }
            field("Voice ID", text: $endpoint.voiceID, prompt: "Sent as {{voice_id}}")
            VStack(alignment: .leading, spacing: 5) {
                Text("JSON body").font(Theme.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $endpoint.bodyTemplate)
                    .font(Theme.mono(11))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(6)
                    .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderSubtle))
                Text("Placeholders: {{text}}, {{language}}, {{voice_id}}").font(Theme.ui(11)).foregroundStyle(Theme.textMuted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Response").font(Theme.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
                FieldMenu(
                    title: endpoint.responseFormat.rawValue,
                    options: CustomEndpoint.ResponseFormat.allCases.map { ($0.rawValue, $0.rawValue) },
                    selection: endpoint.responseFormat.rawValue
                ) { endpoint.responseFormat = CustomEndpoint.ResponseFormat(rawValue: $0) ?? .audioFile }
            }
            if endpoint.responseFormat == .pcm16 {
                field("Sample rate", text: Binding(get: { "\(endpoint.pcmSampleRate)" }, set: { endpoint.pcmSampleRate = Int($0) ?? 24000 }), prompt: "24000")
            }
            if endpoint.responseFormat == .jsonBase64 {
                field("Base64 field", text: $endpoint.jsonField, prompt: "audio_content")
            }
        }
        .padding(.bottom, 14)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(Theme.ui(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.borderSubtle))
        }
    }
}

public enum AppLinks {
    public static let issues = URL(string: "https://github.com/joshuaswanson/slides-to-video/issues")!
    public static let coffee = URL(string: "https://buymeacoffee.com/swanson")!
}

struct FooterLink: View {
    let title: String
    let systemImage: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .labelStyle(EditorLabelStyle())
                .font(Theme.ui(12, .medium))
                .foregroundStyle(hovering ? Theme.green : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
