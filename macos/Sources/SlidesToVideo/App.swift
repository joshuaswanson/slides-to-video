import AppKit
import SlidesToVideoKit
import SwiftUI

@main
struct SlidesToVideoApp: App {
    @State private var model = AppModel()

    init() {
        Askpass.runHelperIfRequested()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Slides to Video", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1040, minHeight: 640)
                .ignoresSafeArea()
                .onAppear { NSApplication.shared.activate() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(replacing: .help) {
                Link("Report an Issue…", destination: AppLinks.issues)
                Link("Buy Me a Coffee…", destination: AppLinks.coffee)
            }
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
