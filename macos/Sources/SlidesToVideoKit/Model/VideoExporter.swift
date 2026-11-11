import AVFoundation
import CoreGraphics
import PDFKit

public enum ExportError: LocalizedError {
    case writerFailed(String)
    case missingPage(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .writerFailed(let detail): "Video export failed: \(detail)"
        case .missingPage(let num): "Slide \(num) has no PDF page"
        case .cancelled: "Export cancelled"
        }
    }
}

/// Encodes slide images and the narration track into an H.264 and AAC movie.
public enum VideoExporter {
    public static let fps = 30

    /// Renders each page at `height`, keeping the first page's aspect ratio for the whole video.
    public static func renderFrames(pages: [PDFPage], height: Int) -> [CGImage] {
        guard let first = pages.first else { return [] }
        let bounds = first.bounds(for: .mediaBox)
        var width = Int((Double(height) * bounds.width / bounds.height).rounded())
        width += width % 2
        return pages.compactMap { render($0, width: width, height: height) }
    }

    static func render(_ page: PDFPage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let box = page.bounds(for: .mediaBox)
        let scale = min(CGFloat(width) / box.width, CGFloat(height) / box.height)
        let target = CGRect(
            x: (CGFloat(width) - box.width * scale) / 2, y: (CGFloat(height) - box.height * scale) / 2,
            width: box.width * scale, height: box.height * scale
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.interpolationQuality = .high
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    public static func export(
        track: NarrationTrack, frames: [CGImage], to url: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let first = frames.first, frames.count == track.slideStarts.count else {
            throw ExportError.writerFailed("expected one image per slide")
        }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = first.width, height = first.height

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 3),
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "could not start") }
        writer.startSession(atSourceTime: .zero)

        let buffers = try frames.map { try pixelBuffer($0) }
        let frameCount = max(1, Int((track.duration * Double(fps)).rounded(.up)))
        let format = try audioFormat(sampleRate: track.sampleRate)
        let chunk = 4096

        let videoFeed = Feed(count: frameCount) { index in
            guard adaptor.assetWriterInput.isReadyForMoreMediaData else { return false }
            let time = Double(index) / Double(fps)
            return adaptor.append(buffers[track.slideIndex(at: time)], withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        let audioFeed = Feed(count: (track.samples.count + chunk - 1) / chunk) { index in
            let start = index * chunk
            let samples = Array(track.samples[start..<min(start + chunk, track.samples.count)])
            guard let buffer = try? sampleBuffer(samples, at: start, format: format, sampleRate: track.sampleRate) else { return false }
            return audio.append(buffer)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await videoFeed.run(on: video, queue: DispatchQueue(label: "export.video"), isCancelled: isCancelled) { done in
                    progress(Double(done) / Double(frameCount))
                }
            }
            group.addTask {
                try await audioFeed.run(on: audio, queue: DispatchQueue(label: "export.audio"), isCancelled: isCancelled) { _ in }
            }
            do {
                try await group.waitForAll()
            } catch {
                let underlying = writer.error
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                if let underlying, case ExportError.writerFailed = error {
                    throw ExportError.writerFailed(underlying.localizedDescription + " " + String(describing: (underlying as NSError).userInfo))
                }
                throw error
            }
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress(1)
    }

    /// Appends `count` items to a writer input as fast as it accepts them.
    final class Feed: @unchecked Sendable {
        let count: Int
        let append: (Int) -> Bool
        private var next = 0

        init(count: Int, append: @escaping (Int) -> Bool) {
            self.count = count
            self.append = append
        }

        func run(on input: AVAssetWriterInput, queue: DispatchQueue, isCancelled: @escaping @Sendable () -> Bool, progress: @escaping (Int) -> Void) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData && next < count {
                        if isCancelled() {
                            finished = true
                            input.markAsFinished()
                            continuation.resume(throwing: ExportError.cancelled)
                            return
                        }
                        guard append(next) else {
                            finished = true
                            input.markAsFinished()
                            continuation.resume(throwing: ExportError.writerFailed("could not append sample \(next)"))
                            return
                        }
                        next += 1
                        if next % 30 == 0 { progress(next) }
                    }
                    if next >= count {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                    }
                }
            }
        }
    }

    static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw ExportError.writerFailed("could not allocate a frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    static func audioFormat(sampleRate: Int) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw ExportError.writerFailed("could not describe audio") }
        return format
    }

    static func sampleBuffer(_ samples: [Float], at offset: Int, format: CMAudioFormatDescription, sampleRate: Int) throws -> CMSampleBuffer {
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw ExportError.writerFailed("could not allocate audio") }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard let buffer else { throw ExportError.writerFailed("could not wrap audio") }
        return buffer
    }
}

/// SRT subtitles with one cue per slide that has narration, timed to the narration track.
public enum Subtitles {
    public static func srt(slides: [Slide], track: NarrationTrack) -> String {
        var entries: [String] = []
        for (slide, span) in zip(slides, track.narrationSpans) {
            let text = Script.stripPauses(slide.narration)
            guard !text.isEmpty, span.end > span.start else { continue }
            entries.append("\(entries.count + 1)\n\(timestamp(span.start)) --> \(timestamp(span.end))\n\(text)\n")
        }
        return entries.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }
}

extension Project {
    @MainActor
    public func exportVideo(
        to url: URL, clickURL: URL?,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let track = try narrationTrack(clickURL: clickURL)
        let pages = try slides.map { slide in
            guard let page = page(for: slide) else { throw ExportError.missingPage(slide.num) }
            return page
        }
        let frames = VideoExporter.renderFrames(pages: pages, height: settings.videoHeight)
        try await VideoExporter.export(track: track, frames: frames, to: url, isCancelled: isCancelled, progress: progress)
        if settings.exportSubtitles {
            try Subtitles.srt(slides: slides, track: track)
                .write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        }
    }
}
