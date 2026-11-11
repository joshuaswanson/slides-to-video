import Foundation

/// A slide in `script.md`: its PDF page number and narration.
public struct Slide: Equatable, Identifiable, Sendable {
    public let num: Int
    public var text: String
    public var id: Int { num }

    public init(num: Int, text: String) {
        self.num = num
        self.text = text
    }

    /// The text sent to TTS, with paragraphs joined into one line.
    public var narration: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum ScriptError: LocalizedError, Equatable {
    case duplicateSlide(Int)
    case slideNotFound(Int)
    case separatorInText
    case headingInText

    public var errorDescription: String? {
        switch self {
        case .duplicateSlide(let num): "Slide \(num) appears more than once in the script"
        case .slideNotFound(let num): "Slide \(num) not found in script"
        case .separatorInText: "Narration cannot contain a line with only '---'"
        case .headingInText: "Narration lines cannot start with '#'"
        }
    }
}

public enum PauseItem: Equatable, Sendable {
    case speech(String)
    case pause(Double)
}

public enum Script {
    public static let defaultInlinePause = 0.5

    nonisolated(unsafe) static let separator = #/^---[ \t]*$/#.anchorsMatchLineEndings()
    nonisolated(unsafe) static let slideHeading = #/^##\s+Slide\s+(\d+)/#.anchorsMatchLineEndings()
    nonisolated(unsafe) static let pauseMarker = #/\[pause(?:\s+(\d+(?:\.\d+)?|\.\d+))?\]/#

    public static func parse(_ content: String) throws -> [Slide] {
        var slides: [Slide] = []
        var seen = Set<Int>()
        for block in blocks(content) where !block.isSeparator {
            let text = String(content[block.range])
            guard let num = headingNumber(text) else { continue }
            if !seen.insert(num).inserted { throw ScriptError.duplicateSlide(num) }
            let body = lines(text).filter { !isHeading($0) }
            slides.append(Slide(num: num, text: paragraphs(body)))
        }
        return slides
    }

    /// Replaces one slide's narration and keeps every other byte of the file.
    public static func updateSlideText(_ content: String, slide num: Int, text: String) throws -> String {
        let newText = try validate(text)
        for block in blocks(content) where !block.isSeparator {
            let original = String(content[block.range])
            guard headingNumber(original) == num else { continue }
            let headings = lines(original).filter(isHeading).joined(separator: "\n")
            let body = newText.isEmpty ? headings : headings + "\n\n" + newText
            let leading = original.prefix { $0.isWhitespace }
            let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
            var result = content
            result.replaceSubrange(block.range, with: leading + body + trailing)
            return result
        }
        throw ScriptError.slideNotFound(num)
    }

    /// Creates a script with one empty slide section per PDF page.
    public static func template(pageCount: Int) -> String {
        (1...max(pageCount, 1))
            .map { "## Slide \($0)\n" }
            .joined(separator: "\n---\n\n")
    }

    public static func splitPauses(_ text: String) -> [PauseItem] {
        var items: [PauseItem] = []
        var cursor = text.startIndex
        func appendSpeech(_ piece: Substring) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { items.append(.speech(trimmed)) }
        }
        for match in text.matches(of: pauseMarker) {
            appendSpeech(text[cursor..<match.range.lowerBound])
            items.append(.pause(match.output.1.flatMap { Double($0) } ?? defaultInlinePause))
            cursor = match.range.upperBound
        }
        appendSpeech(text[cursor...])
        return items
    }

    public static func stripPauses(_ text: String) -> String {
        text.replacing(pauseMarker, with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    struct Block {
        let range: Range<String.Index>
        let isSeparator: Bool
    }

    static func blocks(_ content: String) -> [Block] {
        var result: [Block] = []
        var cursor = content.startIndex
        for match in content.matches(of: separator) {
            result.append(Block(range: cursor..<match.range.lowerBound, isSeparator: false))
            result.append(Block(range: match.range, isSeparator: true))
            cursor = match.range.upperBound
        }
        result.append(Block(range: cursor..<content.endIndex, isSeparator: false))
        return result
    }

    static func headingNumber(_ block: String) -> Int? {
        block.firstMatch(of: slideHeading).flatMap { Int($0.output.1) }
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func isHeading(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.hasPrefix("#")
    }

    static func paragraphs(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs.joined(separator: "\n\n")
    }

    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in lines(trimmed) {
            if line.wholeMatch(of: separator) != nil { throw ScriptError.separatorInText }
            if isHeading(line) { throw ScriptError.headingInText }
        }
        return paragraphs(lines(trimmed))
    }
}
