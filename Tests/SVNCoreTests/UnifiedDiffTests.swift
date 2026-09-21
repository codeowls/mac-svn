import Foundation
import Testing
@testable import SVNCore

struct UnifiedDiffTests {
    @Test func keepsHunkNumbersAndUnpairedChanges() throws {
        let document = UnifiedDiff("""
        --- old
        +++ new
        @@ -2,3 +2,2 @@
         context
        -removed one
        -removed two
        +added
        @@ -20,0 +20 @@
        +new section
        """)
        #expect(document.additions == 2)
        #expect(document.deletions == 2)
        #expect(document.hunkIDs == [2, 7])
        #expect(document.lines[3].oldNumber == 2)
        #expect(document.lines[3].newNumber == 2)
        #expect(document.lines[5].oldNumber == 4)
        #expect(document.lines[8].oldNumber == nil)
        #expect(document.lines[8].newNumber == 20)
        let paired = try #require(document.splitRows.first { $0.left?.text == "-removed one" })
        #expect(paired.right?.text == "+added")
        let unpaired = try #require(document.splitRows.first { $0.left?.text == "-removed two" })
        #expect(unpaired.right == nil)
        #expect(Set(document.splitRows.map(\.id)).count == document.splitRows.count)
    }

    @Test func excludesHeadersAndPropertiesFromTextStatistics() {
        let document = UnifiedDiff("""
        --- old
        +++ new
        @@ -1 +1 @@
        -before
        +after
        Property changes on: file
        -old property
        +new property
        Cannot display: file marked as a binary type.
        """)
        #expect(document.additions == 1)
        #expect(document.deletions == 1)
        #expect(document.hunkIDs == [2])
        #expect(document.containsBinaryNotice)
        #expect(document.lines.last?.kind == .metadata)
    }

    @Test func preservesEmptyLinesAndNoNewlineDiagnostics() {
        let document = UnifiedDiff("@@ -1 +1 @@\n-\n\\ No newline at end of file\n+\n\\ No newline at end of file\n")
        #expect(document.lines.count == 5)
        #expect(document.additions == 1)
        #expect(document.deletions == 1)
        #expect(document.lines[1].oldNumber == 1)
        #expect(document.lines[3].newNumber == 1)
        #expect(document.lines[2].kind == .metadata)
        #expect(UnifiedDiff("").lines.isEmpty)
        #expect(UnifiedDiff("\n").lines.count == 1)
    }

    @Test func binaryNoticeInsideContentIsStillText() {
        let document = UnifiedDiff("@@ -0,0 +1 @@\n+Cannot display: file marked as a binary type.\n")
        #expect(!document.containsBinaryNotice)
        #expect(document.additions == 1)
    }

    @Test func largeDiffRetainsEveryLineAndCanCancelDuringParsingOrPairing() throws {
        let text = "@@ -1,10000 +1,10000 @@\n" +
            Array(repeating: "-old\n", count: 10000).joined() +
            Array(repeating: "+new\n", count: 10000).joined()
        var checks = 0
        let document = UnifiedDiff(text) { checks += 1 }
        #expect(document.lines.count == 20001)
        #expect(document.splitRows.count == 10001)
        #expect(document.additions == 10000)
        #expect(document.deletions == 10000)
        #expect(document.splitRows.last?.left?.oldNumber == 10000)
        #expect(document.splitRows.last?.right?.newNumber == 10000)
        #expect(checks > 100)
        for cancelAt in [1, 10, 100] {
            var count = 0
            #expect(throws: CancellationError.self) {
                try UnifiedDiff(text) {
                    count += 1
                    if count == cancelAt { throw CancellationError() }
                }
            }
            #expect(count == cancelAt)
        }
    }
}
