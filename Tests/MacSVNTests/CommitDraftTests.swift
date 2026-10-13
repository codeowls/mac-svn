import Foundation
import Testing
@testable import SVNCore
@testable import MacSVN

@MainActor
struct CommitDraftTests {
    @Test func storeRestartsAndIsolatesCopiesAndRepositories() throws {
        let store = CommitDraftStore(url: temporaryURL())
        let first = key("/fixture/one", repository: "file:///repository")
        let second = key("/fixture/two", repository: "file:///repository")
        let switched = key("/fixture/one", repository: "file:///other")
        try store.update([first: "中文草稿\nsecond line", second: "other copy", switched: "other repository"])
        let restarted = CommitDraftStore(url: store.url)
        #expect(try restarted.message(for: first) == "中文草稿\nsecond line")
        #expect(try restarted.message(for: second) == "other copy")
        #expect(try restarted.message(for: switched) == "other repository")
        try restarted.update([first: ""])
        #expect(try store.message(for: first).isEmpty)
        #expect(try store.message(for: switched) == "other repository")
        try restarted.update([:], removingRoot: "/fixture/one")
        #expect(try store.message(for: switched).isEmpty)
        #expect(try store.message(for: second) == "other copy")
    }

    @Test func invalidStoreIsNotOverwrittenAndFailedSaveCanBeRetried() throws {
        let store = CommitDraftStore(url: temporaryURL())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("invalid draft document".utf8)
        try invalid.write(to: store.url)
        let model = AppModel(commitDraftStore: store)
        model.workingCopy = WorkingCopy(root: URL(fileURLWithPath: "/fixture"), repositoryURL: "file:///repo", revision: "1")
        model.message = "Keep unsaved draft"
        #expect(model.draftPersistenceError != nil)
        #expect(!model.flushCommitDrafts())
        #expect(try Data(contentsOf: store.url) == invalid)
        try Data("{\"version\":1,\"records\":[]}".utf8).write(to: store.url)
        #expect(model.flushCommitDrafts())
        #expect(model.draftPersistenceError == nil)
        #expect(try store.message(for: WorkingCopyDraftKey(model.workingCopy!)) == "Keep unsaved draft")
    }

    @Test func modelRestoresOnlyMessageAndClearsDraftOnlyAfterSuccessfulCommit() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        let output = try await ProcessRunner.run(executable: svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), arguments: ["create", repository.path])
        try #require(output.exitCode == 0)
        let client = SVNClient(executable: svn)
        let root = fixture.appendingPathComponent("working-copy")
        _ = try await client.checkout(repository: repository.absoluteString, destination: root)
        let file = root.appendingPathComponent("file.txt")
        try Data("initial\n".utf8).write(to: file)
        _ = try await client.add(paths: ["file.txt"], at: root)
        let store = CommitDraftStore(url: fixture.appendingPathComponent("drafts.json"))
        let first = AppModel(commitDraftStore: store)
        first.executablePath = svn.path
        first.open(root)
        try await waitUntil { !first.isBusy && first.workingCopy != nil }
        first.selectedPaths = ["file.txt"]
        first.message = "Draft across restart"
        let restarted = AppModel(commitDraftStore: store)
        restarted.executablePath = svn.path
        restarted.open(root)
        try await waitUntil { !restarted.isBusy && restarted.workingCopy != nil }
        #expect(restarted.message == "Draft across restart")
        #expect(restarted.selectedPaths.isEmpty)
        restarted.selectedPaths = ["file.txt"]
        restarted.prepareCommitSelected()
        try await waitUntil { !restarted.isBusy && restarted.commitPlan != nil }
        let plan = try #require(restarted.commitPlan)
        // 预检后改变文件，使真实提交校验失败；草稿必须仍可恢复。
        try Data("changed after preflight\n".utf8).write(to: file)
        restarted.commitSelected(plan)
        try await waitUntil { !restarted.isBusy }
        #expect(restarted.message == "Draft across restart")
        let draftKey = WorkingCopyDraftKey(try #require(restarted.workingCopy))
        #expect(try store.message(for: draftKey) == "Draft across restart")
        restarted.prepareCommitSelected()
        try await waitUntil { !restarted.isBusy && restarted.commitPlan != nil }
        restarted.commitSelected(try #require(restarted.commitPlan))
        try await waitUntil { !restarted.isBusy }
        #expect(restarted.message.isEmpty)
        #expect(try store.message(for: draftKey).isEmpty)
        first.removeRecentPath(root.path)
        restarted.removeRecentPath(root.path)
    }

    private func key(_ path: String, repository: String) -> WorkingCopyDraftKey {
        WorkingCopyDraftKey(WorkingCopy(root: URL(fileURLWithPath: path), repositoryURL: repository, revision: "1"))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mac-svn-drafts-\(UUID().uuidString)/drafts.json")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }
}
