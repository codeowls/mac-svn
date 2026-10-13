import Foundation
import Testing
@testable import SVNCore

struct RemoteChangesTests {
    @Test func overlapUsesPathComponentsAndDirectoryReplacement() throws {
        let xml = """
        <status><target path=".">
        <entry path="dir"><wc-status item="normal" props="none"/><repos-status item="deleted" props="none"/></entry>
        <entry path="dir/file"><wc-status item="modified" props="none"/></entry>
        <entry path="directory/file"><wc-status item="modified" props="none"/></entry>
        <entry path="new"><wc-status item="unversioned" props="none"/></entry>
        <entry path="new/file"><wc-status item="none" props="none"/><repos-status item="added" props="none"/></entry>
        <entry path="prop"><wc-status item="normal" props="modified"/><repos-status item="normal" props="modified"/></entry>
        <against revision="7"/></target></status>
        """
        let result = try RemoteChanges.parse(xml, at: URL(fileURLWithPath: "/fixture"))
        #expect(result.revision == "7")
        #expect(result.items.map(\.path) == ["dir", "new/file", "prop"])
        #expect(result.items[0].localOverlaps.map(\.path) == ["dir/file"])
        #expect(result.items[1].localOverlaps.map(\.path) == ["new"])
        #expect(result.items[2].localOverlaps.map(\.path) == ["prop"])
    }

    @Test func invalidRemoteResponseDoesNotPretendToBeEmpty() {
        for xml in [
            "<status><target/></status>",
            "<status><target><against revision=\"invalid\"/></target></status>",
            "<status><target><entry path=\"a\"><repos-status item=\"unknown\" props=\"none\"/></entry><against revision=\"1\"/></target></status>"
        ] {
            #expect(throws: SVNError.self) {
                try RemoteChanges.parse(xml, at: URL(fileURLWithPath: "/fixture"))
            }
        }
    }
}
