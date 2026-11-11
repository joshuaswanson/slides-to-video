import Foundation
import Testing
@testable import SlidesToVideoKit

/// Compares the Swift port with outputs recorded from the Python package by
/// `macos/scripts/make_parity_fixture.py`.
struct ParityTests {
    struct Fixture: Decodable {
        struct ScriptCase: Decodable {
            struct ParsedSlide: Decodable { let num: Int; let text: String; let narration: String }
            let content: String
            let slides: [ParsedSlide]
        }
        struct UpdateCase: Decodable {
            let script: Int; let slide: Int; let text: String
            let result: String?; let error: String?
        }
        struct PauseCase: Decodable {
            let text: String; let items: [Item]; let stripped: String
        }
        enum Item: Decodable, Equatable {
            case speech(String), pause(Double)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .speech(text) }
                else { self = .pause(try container.decode(Double.self)) }
            }
        }
        struct HashCase: Decodable { let parts: [String]; let hash: String }

        let scripts: [ScriptCase]
        let updates: [UpdateCase]
        let pauses: [PauseCase]
        let hashes: [HashCase]
    }

    let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    @Test func parseMatchesPython() throws {
        for script in fixture.scripts {
            let slides = try Script.parse(script.content)
            #expect(slides.map(\.num) == script.slides.map(\.num))
            #expect(slides.map(\.text) == script.slides.map(\.text))
            #expect(slides.map(\.narration) == script.slides.map(\.narration))
        }
    }

    @Test func updateMatchesPython() {
        for update in fixture.updates {
            let content = fixture.scripts[update.script].content
            let result = Result { try Script.updateSlideText(content, slide: update.slide, text: update.text) }
            switch result {
            case .success(let text):
                #expect(update.error == nil, "Python raised \(update.error ?? "") for slide \(update.slide)")
                #expect(text == update.result)
            case .failure(let error):
                #expect(update.result == nil, "Swift threw \(error) for slide \(update.slide)")
            }
        }
    }

    @Test func updateWithSameTextIsIdentityOnCanonicalScript() throws {
        for script in fixture.scripts.prefix(1) {
            for slide in try Script.parse(script.content) {
                #expect(try Script.updateSlideText(script.content, slide: slide.num, text: slide.text) == script.content)
            }
        }
    }

    @Test func pausesMatchPython() {
        for pause in fixture.pauses {
            let items = Script.splitPauses(pause.text).map { item -> Fixture.Item in
                switch item {
                case .speech(let text): .speech(text)
                case .pause(let seconds): .pause(seconds)
                }
            }
            #expect(items == pause.items)
            #expect(Script.stripPauses(pause.text) == pause.stripped)
        }
    }

    @Test func textHashMatchesPython() {
        for hash in fixture.hashes {
            #expect(Hashing.textHash(hash.parts) == hash.hash)
        }
    }
}
