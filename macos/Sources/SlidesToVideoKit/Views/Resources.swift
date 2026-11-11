import AppKit

enum Resources {
    static func url(_ name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    static func image(_ name: String) -> NSImage? {
        url(name, ext: "png").flatMap(NSImage.init(contentsOf:))
    }
}
