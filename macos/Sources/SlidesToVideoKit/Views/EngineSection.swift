import SwiftUI

struct EngineSection: View {
    @Bindable var project: Project
    let speech: SpeechController
    @Bindable var settings = AppSettings.shared

    private var engine: EngineInfo? { EngineInfo.named(project.settings.engine) }

    private var deviceOptions: [String] {
        let known = speech.devices.isEmpty ? ["mps", "cpu"] : speech.devices
        return known.contains(settings.localDevice) ? known : [settings.localDevice] + known
    }

    var body: some View {
        Section("Voice engine") {
            Picker("Engine", selection: $project.settings.engine) {
                if project.settings.engine == nil {
                    Text("Choose…").tag(String?.none)
                }
                ForEach(EngineInfo.all) { Text($0.title).tag(Optional($0.id)) }
            }
            .onChange(of: project.settings.engine) { _, _ in
                speech.stop()
                project.audioDidChange()
            }
            Picker("Device", selection: $settings.localDevice) {
                ForEach(deviceOptions, id: \.self) { Text($0).tag($0) }
            }
            statusRow
            if let engine, !engine.languages.contains(project.settings.language) {
                Label("\(engine.title) only supports English", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch speech.state {
        case .stopped:
            Button("Start Engine") { startEngine() }
                .disabled(engine == nil)
        case .starting(let detail):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                    Spacer()
                    Button("Cancel") { speech.stop() }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        case .ready(let engineID, let device):
            HStack {
                Label("\(EngineInfo.named(engineID)?.title ?? engineID) on \(device)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Stop") { speech.stop() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Engine stopped", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                Button("Start Again") { startEngine() }
            }
        }
    }

    private func startEngine() {
        guard let engine else { return }
        Task { await speech.start(engine: engine, device: settings.localDevice, settings: settings) }
    }
}
