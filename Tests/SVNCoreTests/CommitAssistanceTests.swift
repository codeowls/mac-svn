import Foundation
import Testing
@testable import SVNCore

struct CommitAssistanceTests {
    @Test func nearbySuggestionsRespectDirectoryBoundariesAndActualScope() {
        let items = [
            item("src/main.swift", .modified),
            item("src/selected.swift", .added),
            item("new-folder", .added, directory: true),
            item("removed/old.swift", .deleted)
        ]
        let current = [
            state("src/selected.swift", "added"),
            state("src/新文件 @.swift", "unversioned"),
            state("src/staged.swift", "added"),
            state("src/ignored.cache", "ignored"),
            state("src/external", "external"),
            state("src/modified.swift", "modified"),
            state("src-other/new.swift", "unversioned"),
            state("new-folder/nested/new.swift", "unversioned"),
            state("new-folder-other/new.swift", "unversioned"),
            state("removed/new.swift", "unversioned")
        ]
        let report = CommitAssistance(items: items, current: current)
        #expect(report.nearbyNewItems.map(\.path) == [
            "new-folder/nested/new.swift", "src/staged.swift", "src/新文件 @.swift"
        ])
        #expect(report.fileCount == 3)
        #expect(report.directoryCount == 1)
        #expect(report.changes.reduce(0) { $0 + $1.count } == items.count)
    }

    @Test func temporaryNamesAreAdvisoryForNewContentOnly() {
        let candidates = [".DS_Store", "Thumbs.db", "~$文档.docx", ".file.swp", "copy.BAK", "draft.tmp", "file~"]
        let items = candidates.map { item("src/" + $0, .added) } + [
            item("src/replaced.temp", .replaced),
            item("src/tracked.tmp", .modified),
            item("src/removed.tmp", .deleted),
            item("src/folder.tmp", .added, directory: true),
            item("src/application.log", .added),
            item("src/.env.example", .added)
        ]
        let report = CommitAssistance(items: items, current: [])
        #expect(Set(report.temporaryItems.map(\.path)) == Set(candidates.map { "src/" + $0 } + ["src/replaced.temp"]))
        #expect(report.hasSuggestions)
        #expect(!CommitAssistance(items: [item("README.md", .modified)], current: []).hasSuggestions)
    }

    @Test func summaryDistinguishesPropertiesCopiesAndStructuralItems() {
        #expect(CommitChange(state("copy/file", "normal", copied: true)) == .added)
        #expect(CommitChange(state("copy/file", "modified", copied: true)) == .added)
        #expect(CommitChange(state("file", "normal", properties: "modified")) == .properties)
        #expect(CommitChange(state("file", "modified", properties: "modified")) == .modified)
        #expect(CommitChange(state("file", "deleted", copied: true)) == .deleted)
        #expect(CommitChange(state("folder", "normal")) == .included)
    }

    /// 在隔离的真实 SVN 仓库中验证检查只读、复制子项、忽略规则和最终提交边界；保留样例供检查。
    @Test func realCommitKeepsSuggestionsOutsideTargetsAndRevalidatesContent() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-svn-commit-assistance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        try await run(svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), ["create", repository.path])
        let copy = fixture.appendingPathComponent("中文 @副本")
        try await run(svn, ["checkout", repository.absoluteString, copy.path])
        for directory in ["src", "other", "template"] {
            try FileManager.default.createDirectory(at: copy.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try write("initial\n", "src/main.swift", at: copy)
        try write("template\n", "template/seed.tmp", at: copy)
        try await run(svn, ["add", "--no-ignore", "--", "src", "other", "template"], at: copy)
        try await run(svn, ["commit", "-m", "Initial fixture", "--", ".@"], at: copy)
        try write("changed\n", "src/main.swift", at: copy)
        try write("new\n", "src/selected.swift", at: copy)
        try write("temporary\n", "src/~$文档.docx", at: copy)
        try write("not selected\n", "src/unselected.swift", at: copy)
        try await run(svn, ["add", "--", "src/selected.swift", "src/~$文档.docx", "src/unselected.swift"], at: copy)
        try await run(svn, ["copy", "--", "template", "copied"], at: copy)
        try write("missing from commit\n", "src/新文件 @.swift", at: copy)
        try write("ignored\n", "src/ignored.cache", at: copy)
        try write("other task\n", "other/new.swift", at: copy)
        let client = SVNClient(executable: svn, globalIgnores: "*.cache")
        let before = try await client.status(at: copy)
        let paths = ["src/main.swift", "src/selected.swift", "src/~$文档.docx", "copied"]
        let plan = try await client.prepareCommit(paths: paths, message: "Reviewed commit", at: copy)
        #expect(try await client.status(at: copy) == before)
        #expect(plan.assistance.nearbyNewItems.map(\.path) == ["src/unselected.swift", "src/新文件 @.swift"])
        #expect(plan.assistance.temporaryItems.map(\.path) == ["copied/seed.tmp", "src/~$文档.docx"])
        #expect(plan.items.first { $0.path == "copied/seed.tmp" }?.change == .added)
        #expect(!plan.targets.contains("src/unselected.swift"))
        #expect(!plan.targets.contains("src/新文件 @.swift"))

        try write("changed after review\n", "src/main.swift", at: copy)
        do {
            _ = try await client.commit(plan)
            Issue.record("A changed reviewed file must prevent the stale commit")
        } catch let error as SVNError {
            #expect(error.localizedDescription.contains(L10n.text("确认期间提交内容或范围发生变化，尚未提交。请重新检查。")))
        }
        let fresh = try await client.prepareCommit(paths: paths, message: "Reviewed commit", at: copy)
        _ = try await client.commit(fresh)
        let remaining = try await client.status(at: copy)
        #expect(remaining.first { $0.path == "src/unselected.swift" }?.item == "added")
        #expect(remaining.first { $0.path == "src/新文件 @.swift" }?.item == "unversioned")
        #expect(remaining.first { $0.path == "other/new.swift" }?.item == "unversioned")
        #expect(!remaining.contains { paths.contains($0.path) })
        let history = try await client.history(at: copy)
        #expect(history.first?.message == "Reviewed commit")
        #expect(history.first?.changedPaths.contains { $0.path == "/src/~$文档.docx" } == true)
        #expect(history.first?.changedPaths.contains { $0.path == "/src/unselected.swift" } == false)
    }

    private func item(_ path: String, _ change: CommitChange, directory: Bool = false) -> CommitReviewItem {
        CommitReviewItem(path: path, reason: "test", change: change, isDirectory: directory, snapshot: "test")
    }

    private func state(_ path: String, _ item: String, properties: String = "none", copied: Bool = false) -> StatusEntry {
        StatusEntry(path: path, item: item, properties: properties, treeConflict: false, copied: copied)
    }

    private func write(_ text: String, _ path: String, at root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func run(_ executable: URL, _ arguments: [String], at directory: URL? = nil) async throws {
        let output = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: directory)
        try #require(output.exitCode == 0, "\(output.stderr)")
    }
}
