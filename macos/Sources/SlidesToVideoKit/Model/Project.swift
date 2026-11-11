import Foundation
import Observation
import PDFKit

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var slidesFile: String?
    public var voiceFile: String?
    public var engine: String?
    public var language = "en"
    public var pause = 1.0
    public var speed = 1.0
    public var useClick = true

    public init() {}
}

@MainActor
@Observable
public final class Project {
    public static let scriptName = "script.md"
    public static let settingsName = "slides-to-video.json"

    public let folder: URL
    public var settings: ProjectSettings {
        didSet { if settings != oldValue { try? saveSettings() } }
    }
    public private(set) var slides: [Slide] = []
    public private(set) var pdf: PDFDocument?
    public private(set) var scriptError: String?

    public var scriptURL: URL { folder.appending(path: Self.scriptName) }
    public var cacheURL: URL { folder.appending(path: ".cache") }
    public var audioURL: URL { cacheURL.appending(path: "audio_clips") }
    public var name: String { folder.lastPathComponent }

    public var slidesURL: URL? {
        settings.slidesFile.map { folder.appending(path: $0) }
    }

    public var voiceURL: URL? {
        settings.voiceFile.map { folder.appending(path: $0) }
    }

    init(folder: URL, settings: ProjectSettings) {
        self.folder = folder
        self.settings = settings
    }

    /// Opens an existing project folder, or turns a folder with a PDF into one.
    public static func open(folder: URL) throws -> Project {
        let settingsURL = folder.appending(path: settingsName)
        var settings = ProjectSettings()
        if let data = try? Data(contentsOf: settingsURL) {
            settings = try JSONDecoder().decode(ProjectSettings.self, from: data)
        }
        if settings.slidesFile == nil {
            settings.slidesFile = firstFile(in: folder, extensions: ["pdf"])
        }
        let project = Project(folder: folder, settings: settings)
        project.loadPDF()
        if !FileManager.default.fileExists(atPath: project.scriptURL.path) {
            let pages = project.pdf?.pageCount ?? 1
            try Script.template(pageCount: pages).write(to: project.scriptURL, atomically: true, encoding: .utf8)
        }
        try project.saveSettings()
        project.reloadScript()
        return project
    }

    /// Opens the folder that contains the PDF and uses that PDF as the slides.
    public static func open(pdf: URL) throws -> Project {
        let folder = pdf.deletingLastPathComponent()
        let project = try open(folder: folder)
        project.settings.slidesFile = pdf.lastPathComponent
        project.loadPDF()
        return project
    }

    public func reloadScript() {
        do {
            slides = try Script.parse(String(contentsOf: scriptURL, encoding: .utf8))
            scriptError = nil
        } catch {
            scriptError = error.localizedDescription
        }
    }

    public func updateText(slide num: Int, text: String) throws {
        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        let updated = try Script.updateSlideText(content, slide: num, text: text)
        if updated != content {
            try updated.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        reloadScript()
    }

    public func setSlides(_ url: URL) throws {
        settings.slidesFile = try importFile(url)
        loadPDF()
    }

    public func setVoice(_ url: URL) throws {
        settings.voiceFile = try importFile(url)
    }

    public func page(for slide: Slide) -> PDFPage? {
        guard let pdf, slide.num >= 1, slide.num <= pdf.pageCount else { return nil }
        return pdf.page(at: slide.num - 1)
    }

    func loadPDF() {
        pdf = slidesURL.flatMap(PDFDocument.init(url:))
    }

    func saveSettings() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: folder.appending(path: Self.settingsName), options: .atomic)
    }

    /// Copies a file into the project folder unless it is already there, and returns its relative path.
    func importFile(_ url: URL) throws -> String {
        let standardFolder = folder.standardizedFileURL.path
        if url.standardizedFileURL.deletingLastPathComponent().path == standardFolder {
            return url.lastPathComponent
        }
        let destination = folder.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return url.lastPathComponent
    }

    static func firstFile(in folder: URL, extensions: Set<String>) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().first { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
}
