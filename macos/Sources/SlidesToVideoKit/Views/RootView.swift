import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let project = model.project {
                ProjectView(project: project)
                    .id(project.folder)
            } else {
                WelcomeView(model: model)
            }
        }
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
        VStack(spacing: 24) {
            if let logo = Resources.image("AppIcon") {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 128, height: 128)
            }
            VStack(spacing: 6) {
                Text("Slides \(Text("to").italic().foregroundStyle(.green)) Video")
                    .font(.system(size: 34, weight: .semibold))
                Text("Turn a slide deck and a script into a narrated video.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("New from PDF…") { model.choosePDF() }
                    .keyboardShortcut("n")
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                Button("Open Project Folder…") { model.chooseProjectFolder() }
                    .keyboardShortcut("o")
                    .controlSize(.large)
            }
        }
        .padding(60)
        .frame(minWidth: 640, minHeight: 440)
    }
}
