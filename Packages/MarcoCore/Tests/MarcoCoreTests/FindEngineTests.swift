import Testing
@testable import MarcoCore

struct FindEngineTests {

    @Test func matchesAcrossMultipleSegmentsInOrder() {
        let segments = ["hello world", "world of hello"]
        let matches = FindEngine.search(query: "hello", in: segments)

        #expect(matches.count == 2)
        #expect(matches[0].id == 0)
        #expect(matches[0].segmentIndex == 0)
        #expect(matches[0].start == 0)
        #expect(matches[0].length == 5)

        #expect(matches[1].id == 1)
        #expect(matches[1].segmentIndex == 1)
        #expect(matches[1].start == 9)
        #expect(matches[1].length == 5)
    }

    @Test func caseInsensitiveByDefault() {
        let matches = FindEngine.search(query: "the", in: ["The cat sat"])
        #expect(matches.count == 1)
        #expect(matches[0].start == 0)
    }

    @Test func caseSensitiveOptOutExcludesDifferentCase() {
        let matches = FindEngine.search(query: "the", in: ["The cat sat"], caseSensitive: true)
        #expect(matches.isEmpty)
    }

    @Test func emptyQueryReturnsNoMatches() {
        #expect(FindEngine.search(query: "", in: ["anything"]).isEmpty)
        #expect(FindEngine.search(query: "   ", in: ["anything"]).isEmpty)
    }

    @Test func overlappingPatternDoesNotOverlap() {
        let matches = FindEngine.search(query: "aa", in: ["aaaa"])
        #expect(matches.count == 2)
        #expect(matches[0].start == 0)
        #expect(matches[1].start == 2)
    }

    @Test func queryLongerThanAnySegmentReturnsNoMatches() {
        let matches = FindEngine.search(query: "a very long query string", in: ["short"])
        #expect(matches.isEmpty)
    }

    @Test func unicodeEmojiOffsetsAreCharacterBased() {
        // "a😀bc" is 4 Characters (grapheme clusters): a, 😀, b, c — so
        // "bc" starts at Character offset 2, not the UTF-16 offset (3)
        // an emoji's surrogate pair would imply.
        let matches = FindEngine.search(query: "bc", in: ["a😀bc"])
        #expect(matches.count == 1)
        #expect(matches[0].start == 2)
        #expect(matches[0].length == 2)
    }
}
