import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
        Theme.registerFonts()
    }

    public var body: some View {
        Group {
            if let project = model.project {
                ProjectView(project: project, model: model)
                    .id(project.folder)
            } else {
                WelcomeView(model: model)
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            "Could not open project",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Theme.bgPrimary
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Wordmark(size: 44)
                    Text("Turn a slide deck and a script into a narrated video.")
                        .font(Theme.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    Button {
                        model.choosePDF()
                    } label: {
                        Label("New from PDF", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.editor(.primary))
                    Button {
                        model.chooseProjectFolder()
                    } label: {
                        Label("Open Project Folder", systemImage: "folder")
                    }
                    .buttonStyle(.editor(.secondary))
                }
            }
        }
        .gesture(WindowDragGesture())
    }
}
