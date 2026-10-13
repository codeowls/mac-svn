import Foundation
import Testing
@testable import SVNCore

struct DiffReadingTests {
    @Test func highlightsOnlyChangedWordsInPairedRows() throws {
        let document = UnifiedDiff("@@ -1 +1 @@\n-let price = 100;\n+let price = 200;\n")
        let reading = DiffReading(document: document)
        let old = document.lines[1].text as NSString
        let new = document.lines[2].text as NSString
        #expect(reading.wordRanges[1]?.map { old.substring(with: $0) } == ["100"])
        #expect(reading.wordRanges[2]?.map { new.substring(with: $0) } == ["200"])
        #expect(reading.wordRanges[0] == nil)
    }

    @Test func unicodeHighlightsPreserveGraphemesAndRepeatedTokens() {
        let document = UnifiedDiff("@@ -1 +1 @@\n-名字🙂 café call(foo, foo)\n+名字🙃 café call(foo, bar)\n")
        let reading = DiffReading(document: document)
        let old = document.lines[1].text as NSString
        let new = document.lines[2].text as NSString
        #expect(reading.wordRanges[1]?.map { old.substring(with: $0) } == ["🙂", "foo"])
        #expect(reading.wordRanges[2]?.map { new.substring(with: $0) } == ["🙃", "bar"])
    }

    @Test func unpairedContentIsHighlightedAndPropertiesRemainMetadata() {
        let document = UnifiedDiff("@@ -0,0 +1 @@\n+brand new line\nProperty changes on: file\n+new property\n")
        let reading = DiffReading(document: document)
        #expect(reading.wordRanges[1] == [NSRange(location: 1, length: 14)])
        #expect(reading.wordRanges[3] == nil)
    }

    @Test func searchIsCaseInsensitiveAndRetainsEveryOccurrenceAndUnicodeRange() {
        let document = UnifiedDiff("@@ -1 +1 @@\n-Foo foo🙂\n+FOO 中文foo🙂\n")
        let matches = DiffReading.search(document: document, query: "foo")
        #expect(matches.map(\.lineID) == [1, 1, 2, 2])
        #expect(matches.map { (document.lines[$0.lineID].text as NSString).substring(with: $0.range).lowercased() } == ["foo", "foo", "foo", "foo"])
        let unicode = DiffReading.search(document: document, query: "🙂")
        #expect(unicode.count == 2)
        #expect(unicode.allSatisfy { $0.range.length == 2 })
        #expect(DiffReading.search(document: document, query: "").isEmpty)
        #expect(DiffReading.search(document: document, query: "not present").isEmpty)
    }

    @Test func rightSideMatchKeepsItsSourceLineIdentityAndSkipsPatchMarkers() throws {
        let document = UnifiedDiff("@@ -1 +1 @@\n-old value\n+new NEEDLE value\n")
        let match = try #require(DiffReading.search(document: document, query: "needle").first)
        let row = try #require(document.splitRows.first { $0.right?.id == match.lineID })
        #expect(row.left?.id != match.lineID)
        #expect((row.right!.text as NSString).substring(with: match.range) == "NEEDLE")
        #expect(DiffReading.search(document: document, query: "+").map(\.lineID) == [0])
    }

    @Test func largeDiffReadingAndSearchCanBeCancelled() throws {
        let text = "@@ -1,10000 +1,10000 @@\n" + String(repeating: "-old name\n", count: 10000)
            + String(repeating: "+new name\n", count: 10000)
        let document = UnifiedDiff(text)
        for cancelAt in [1, 20, 100] {
            var checks = 0
            #expect(throws: CancellationError.self) {
                try DiffReading(document: document) {
                    checks += 1
                    if checks == cancelAt { throw CancellationError() }
                }
            }
            checks = 0
            #expect(throws: CancellationError.self) {
                try DiffReading.search(document: document, query: "name") {
                    checks += 1
                    if checks == cancelAt { throw CancellationError() }
                }
            }
        }
        let reading = DiffReading(document: document)
        #expect(reading.wordRanges.count == 20000)
        #expect(DiffReading.search(document: document, query: "name").count == 20000)
    }
}
