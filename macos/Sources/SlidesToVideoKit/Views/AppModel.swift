import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppModel {
    private static let lastProjectKey = "lastProjectFolder"

    public var project: Project?
    public var errorMessage: String?

    public init() {
        if let path = UserDefaults.standard.string(forKey: Self.lastProjectKey),
           FileManager.default.fileExists(atPath: path) {
            open { try Project.open(folder: URL(filePath: path)) }
        }
    }

    public func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder with a script.md and a slides PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open { try Project.open(folder: url) }
    }

    public func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Start Project"
        panel.message = "The project is created in the PDF's folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open { try Project.open(pdf: url) }
    }

    public func closeProject() {
        project = nil
        UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
    }

    private func open(_ make: () throws -> Project) {
        do {
            let project = try make()
            self.project = project
            UserDefaults.standard.set(project.folder.path, forKey: Self.lastProjectKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
