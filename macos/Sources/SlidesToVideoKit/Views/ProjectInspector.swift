import SwiftUI
import UniformTypeIdentifiers

struct ProjectInspector: View {
    @Bindable var project: Project
    @State private var importError: String?

    private static let languages: [(String, String)] = [
        ("en", "English"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("fr", "French"),
        ("de", "German"), ("es", "Spanish"), ("ar", "Arabic"), ("ru", "Russian"), ("pt", "Portuguese"),
    ]

    var body: some View {
        Form {
            Section("Sources") {
                fileRow("Slides", name: project.settings.slidesFile, types: [.pdf]) { try project.setSlides($0) }
                fileRow("Voice sample", name: project.settings.voiceFile, types: [.audio]) { try project.setVoice($0) }
                LabeledContent("Script") {
                    Button(Project.scriptName) { NSWorkspace.shared.activateFileViewerSelecting([project.scriptURL]) }
                        .buttonStyle(.link)
                }
            }
            Section("Narration") {
                Picker("Language", selection: $project.settings.language) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Pause") {
                    Stepper(value: $project.settings.pause, in: 0...5, step: 0.1) {
                        Text(project.settings.pause, format: .number.precision(.fractionLength(1))) + Text(" s")
                    }
                }
                LabeledContent("Speed") {
                    Stepper(value: $project.settings.speed, in: 0.5...2, step: 0.05) {
                        Text(project.settings.speed, format: .number.precision(.fractionLength(2))) + Text("×")
                    }
                }
                Toggle("Click on slide change", isOn: $project.settings.useClick)
            }
        }
        .formStyle(.grouped)
        .alert("Could not add file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func fileRow(_ title: String, name: String?, types: [UTType], apply: @escaping (URL) throws -> Void) -> some View {
        LabeledContent(title) {
            Button(name ?? "Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try apply(url) } catch { importError = error.localizedDescription }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }
}
