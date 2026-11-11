import SwiftUI

struct ScriptEditor: View {
    let project: Project
    let slide: Slide
    @State private var draft: String
    @State private var status: SaveStatus = .saved
    @State private var pendingSave: Task<Void, Never>?

    enum SaveStatus: Equatable {
        case saved, unsaved, failed(String)
    }

    init(project: Project, slide: Slide) {
        self.project = project
        self.slide = slide
        _draft = State(initialValue: slide.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slide \(slide.num)")
                    .font(.headline)
                Spacer()
                statusLabel
            }
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("Use [pause] or [pause 1.5] for silence. A blank line starts a new paragraph.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: slide.text) { _, newValue in
            if status == .saved { draft = newValue }
        }
        .onDisappear { save() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .saved:
            EmptyView()
        case .unsaved:
            Text("Edited").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func scheduleSave() {
        guard draft != slide.text else { return }
        status = .unsaved
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        guard status != .saved else { return }
        do {
            try project.updateText(slide: slide.num, text: draft)
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
