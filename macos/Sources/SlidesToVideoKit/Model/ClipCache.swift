import Foundation

/// Per-slide clips in `.cache/audio_clips`, with `hashes.json` recording which narration,
/// engine, language, and voice each clip was made from. The key format must stay fixed, or
/// existing projects would regenerate all their audio.
public struct ClipCache {
    public let directory: URL
    public let engineName: String
    public let language: String
    public let hasVoice: Bool
    public let settingsKey: String

    public init(directory: URL, engineName: String, language: String, voiceURL: URL?) {
        self.directory = directory
        self.engineName = engineName
        self.language = language
        let voiceHash = voiceURL.flatMap { try? Hashing.fileHash($0) }
        hasVoice = voiceHash != nil
        settingsKey = Hashing.textHash(engineName, language, voiceHash ?? "")
    }

    public func clipURL(_ num: Int) -> URL {
        directory.appending(path: String(format: "slide_%02d.wav", num))
    }

    public var ambientURL: URL {
        directory.appending(path: "ambient_\(settingsKey).wav")
    }

    var manifestURL: URL { directory.appending(path: "hashes.json") }

    func key(_ slide: Slide) -> String {
        Hashing.textHash(settingsKey, slide.narration)
    }

    func manifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    public func isFresh(_ slide: Slide) -> Bool {
        let url = clipURL(slide.num)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        let entry = manifest()[stem]
        if entry == key(slide) { return true }
        if entry == Hashing.legacyTextHash(slide.narration) {
            if hasVoice { try? setEntry(stem, key(slide)) }
            return true
        }
        return false
    }

    public func store(_ slide: Slide, clip: PCMClip) throws {
        try AudioIO.writeWAV(clip.samples, sampleRate: clip.sampleRate, to: clipURL(slide.num))
        try setEntry(clipURL(slide.num).deletingPathExtension().lastPathComponent, key(slide))
    }

    public func storeAmbient(_ clip: PCMClip) throws {
        try AudioIO.writeWAV(clip.samples, sampleRate: clip.sampleRate, to: ambientURL)
    }

    func setEntry(_ stem: String, _ value: String) throws {
        var entries = manifest()
        entries[stem] = value
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }
}
