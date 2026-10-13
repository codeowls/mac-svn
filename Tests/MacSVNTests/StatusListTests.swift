import Foundation
import Testing
@testable import SVNCore
@testable import MacSVN

@MainActor
struct StatusListTests {
    @Test func categoriesIncludePropertiesAndAllConflictKinds() {
        let properties = entry("props", "normal", props: "modified")
        let replaced = entry("replace", "replaced")
        let added = entry("new", "added", props: "modified")
        let tree = entry("tree", "modified", tree: true)
        let propertyConflict = entry("conflict", "normal", props: "conflicted")
        #expect(StatusFilter.modified.matches(properties))
        #expect(StatusFilter.modified.matches(replaced))
        #expect(!StatusFilter.modified.matches(added))
        #expect(StatusFilter.added.matches(added))
        #expect(!StatusFilter.modified.matches(tree))
        #expect(StatusFilter.conflicts.matches(tree))
        #expect(StatusFilter.conflicts.matches(propertyConflict))
        #expect(StatusFilter.all.matches(entry("missing", "missing")))
    }

    @Test func filteringAndCollapsingPreserveTheExactSelection() {
        let model = AppModel()
        model.entries = [entry("root.txt", "modified"), entry("src/file.txt", "modified"), entry("src-other/new.txt", "added")]
        model.selectedPaths = ["root.txt", "src/file.txt", "src-other/new.txt"]
        model.message = "Keep all selected paths"
        model.statusFilter = .modified
        #expect(model.visibleEntries.map(\.path) == ["root.txt", "src/file.txt"])
        #expect(model.hiddenSelectionCount == 1)
        model.groupByDirectory = true
        model.collapsedDirectories = ["src"]
        #expect(model.statusRows.map(\.id) == ["directory:.", "entry:root.txt", "directory:src"])
        #expect(model.hiddenSelectionCount == 2)
        #expect(model.selectedEntries.count == 3)
        #expect(model.canCommit)
        model.statusFilter = .all
        model.fileFilter = "SRC"
        #expect(model.visibleEntries.map(\.path) == ["src/file.txt", "src-other/new.txt"])
        #expect(model.statusRows.map(\.id) == ["directory:src", "directory:src-other", "entry:src-other/new.txt"])
        model.groupByDirectory = false
        model.fileFilter = ""
        #expect(model.hiddenSelectionCount == 0)
        #expect(model.selectedPaths == ["root.txt", "src/file.txt", "src-other/new.txt"])
        #expect(model.message == "Keep all selected paths")
    }

    private func entry(_ path: String, _ item: String, props: String = "none", tree: Bool = false) -> StatusEntry {
        StatusEntry(path: path, item: item, properties: props, treeConflict: tree, copied: false)
    }
}
