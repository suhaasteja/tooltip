import Testing
@testable import AskAICore

@Suite("Selection extraction")
struct SelectionExtractorTests {

    @Test("nil pasteboard yields no selection")
    func nilInput() {
        #expect(SelectionExtractor.extract(from: nil) == nil)
    }

    @Test("empty and whitespace-only yield no selection")
    func emptyInput() {
        #expect(SelectionExtractor.extract(from: "") == nil)
        #expect(SelectionExtractor.extract(from: "   \t\n\n  ") == nil)
    }

    @Test("trims surrounding whitespace")
    func trims() {
        let s = SelectionExtractor.extract(from: "\n\t  hello world  \n ")
        #expect(s?.text == "hello world")
        #expect(s?.wasTruncated == false)
    }

    @Test("collapses runs of spaces and tabs")
    func collapsesHorizontalRuns() {
        let s = SelectionExtractor.extract(from: "a     b\t\t\tc")
        #expect(s?.text == "a b c")
    }

    @Test("preserves a single line break but collapses blank-line runs")
    func preservesParagraphs() {
        let s = SelectionExtractor.extract(from: "line one\nline two\n\n\n\npara two")
        #expect(s?.text == "line one\nline two\n\npara two")
    }

    @Test("normalizes CRLF to a single break")
    func normalizesCRLF() {
        let s = SelectionExtractor.extract(from: "windows\r\nline\r\nendings")
        #expect(s?.text == "windows\nline\nendings")
    }

    @Test("collapses non-breaking and exotic Unicode spaces")
    func collapsesUnicodeSpaces() {
        let s = SelectionExtractor.extract(from: "a\u{00A0}\u{2003}\u{2009}b")
        #expect(s?.text == "a b")
    }

    @Test("text over the cap is truncated and marked")
    func truncatesOverCap() {
        let long = String(repeating: "x", count: SelectionExtractor.characterCap + 500)
        let s = SelectionExtractor.extract(from: long)
        #expect(s?.wasTruncated == true)
        #expect(s?.originalLength == SelectionExtractor.characterCap + 500)
        #expect(s?.text.hasSuffix(SelectionExtractor.truncationMarker) == true)
        #expect(s?.text.count == SelectionExtractor.characterCap
                + SelectionExtractor.truncationMarker.count)
    }

    @Test("text exactly at the cap is not truncated")
    func capBoundary() {
        let exact = String(repeating: "x", count: SelectionExtractor.characterCap)
        let s = SelectionExtractor.extract(from: exact)
        #expect(s?.wasTruncated == false)
        #expect(s?.text.count == SelectionExtractor.characterCap)
    }

    @Test("unicode and emoji survive intact")
    func preservesUnicode() {
        let input = "café 日本語 🇯🇵 👨‍👩‍👧‍👦 naïve"
        let s = SelectionExtractor.extract(from: input)
        #expect(s?.text == input)
    }

    @Test("grapheme clusters are not split by the cap")
    func doesNotSplitGraphemes() {
        // A family emoji is one Character but many scalars; prefix(_:) works on
        // Characters, so the cluster must survive whole.
        let family = "👨‍👩‍👧‍👦"
        let long = String(repeating: family, count: SelectionExtractor.characterCap + 10)
        let s = SelectionExtractor.extract(from: long)
        #expect(s?.wasTruncated == true)
        let body = s!.text.dropLast(SelectionExtractor.truncationMarker.count)
        #expect(body.allSatisfy { String($0) == family })
    }
}
