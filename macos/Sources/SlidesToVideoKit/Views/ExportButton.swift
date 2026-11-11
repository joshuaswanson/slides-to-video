import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ExportController {
    private(set) var progress: Double?
    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    }

    var isExporting: Bool { progress != nil }

    func start(_ project: Project, toasts: Toasts) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name).mp4"
        panel.directoryURL = project.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        cancelFlag.set(false)
        progress = 0
        let flag = cancelFlag
        task = Task {
            do {
                try await project.exportVideo(
                    to: url, clickURL: Resources.url("click", ext: "wav"),
                    isCancelled: { flag.isSet },
                    progress: { value in Task { @MainActor in if self.progress != nil { self.progress = value } } }
                )
                toasts.show("Video exported", .success)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch ExportError.cancelled {
                toasts.show("Export cancelled")
            } catch {
                toasts.show(error.localizedDescription, .error)
            }
            progress = nil
        }
    }

    func cancel() {
        cancelFlag.set(true)
    }
}

struct ExportButton: View {
    let project: Project
    let controller: ExportController
    let toasts: Toasts
    let beforeExport: () -> Void

    var body: some View {
        Button {
            if controller.isExporting {
                controller.cancel()
            } else {
                beforeExport()
                controller.start(project, toasts: toasts)
            }
        } label: {
            if let progress = controller.progress {
                HStack(spacing: 6) {
                    Spinner(size: 12, color: .white)
                    Text("Exporting \(Int(progress * 100))%")
                        .monospacedDigit()
                }
            } else {
                Label("Export Video", systemImage: "square.and.arrow.down")
            }
        }
        .buttonStyle(.editor(.primary))
        .help(controller.isExporting ? "Click to cancel" : "Export the talk as an MP4 video")
        .keyboardShortcut("e", modifiers: .command)
    }
}
