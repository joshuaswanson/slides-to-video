import SwiftUI

struct GenerateAllButton: View {
    let project: Project
    let speech: SpeechController

    var body: some View {
        if speech.isGeneratingAll {
            Button {
                speech.cancelGenerateAll()
            } label: {
                Label("Stop Generating", systemImage: "stop.circle")
            }
            .help("Stop after the current slide")
        } else {
            Button {
                Task { await speech.generateStale(in: project) }
            } label: {
                Label("Generate All", systemImage: "waveform.badge.plus")
            }
            .help("Generate audio for every slide that needs it")
            .disabled(!speech.isReady || speech.isBusy)
        }
    }
}
