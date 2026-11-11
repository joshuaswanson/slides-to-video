import AVFoundation
import Foundation

public struct PCMClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double { Double(samples.count) / Double(sampleRate) }

    init(pcm16Base64: String, sampleRate: Int) throws {
        guard let data = Data(base64Encoded: pcm16Base64) else { throw AudioError.badPayload }
        let samples = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
        }
        self.init(samples: samples, sampleRate: sampleRate)
    }
}

public enum AudioError: LocalizedError {
    case badPayload
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badPayload: "The worker sent audio that could not be decoded"
        case .conversionFailed(let detail): "Audio conversion failed: \(detail)"
        }
    }
}

public enum AudioIO {
    public static let voiceSampleRate = 24_000

    /// Decodes any audio file AVFoundation can read into mono float samples at `sampleRate`.
    public static func readMono(_ url: URL, sampleRate: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioError.conversionFailed("could not allocate input buffer")
        }
        try file.read(into: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        if source.sampleRate == target.sampleRate, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw AudioError.conversionFailed("no converter from \(source)")
        }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioError.conversionFailed("could not allocate output buffer")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Writes 16-bit mono PCM WAV, the format the Python package writes.
    public static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            if !samples.isEmpty {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try file.write(from: buffer)
            }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func duration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Converts a voice recording to the 24 kHz mono WAV that both TTS engines clone from.
    public static func prepareVoice(from source: URL, to destination: URL) throws {
        try writeWAV(readMono(source, sampleRate: voiceSampleRate), sampleRate: voiceSampleRate, to: destination)
    }
}
