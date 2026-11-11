import AppKit
import SlidesToVideoKit
import SwiftUI

@main
struct SlidesToVideoApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Slides to Video", id: "main") {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New from PDF…") { model.choosePDF() }
                    .keyboardShortcut("n")
                Button("Open Project Folder…") { model.chooseProjectFolder() }
                    .keyboardShortcut("o")
                Divider()
                Button("Close Project") { model.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.project == nil)
            }
        }
    }
}
