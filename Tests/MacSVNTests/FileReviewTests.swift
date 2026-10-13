import Foundation
import Testing
import SVNCore
@testable import MacSVN

@MainActor
struct FileReviewTests {
    @Test func snapshotMatchesCommitAndChangesForBytesAndProperties() async throws {
        let fixture = try await makeFixture()
        let review = try await fixture.client.fileReview(path: "first@.txt", at: fixture.root)
        let plan = try await fixture.client.prepareCommit(paths: ["first@.txt"], message: "Review fixture", at: fixture.root)
        #expect(review.snapshot == plan.items.first?.snapshot)
        #expect(review.diff.contains("first change"))
        try Data("second change\n".utf8).write(to: fixture.root.appendingPathComponent("first@.txt"))
        let changed = try await fixture.client.reviewSnapshot(path: "first@.txt", at: fixture.root)
        #expect(changed != review.snapshot)
        try await command(fixture.client.executable, ["propset", "test:review", "new", "--", "first@.txt@"], at: fixture.root)
        #expect(try await fixture.client.reviewSnapshot(path: "first@.txt", at: fixture.root) != changed)
        try await command(fixture.client.executable, ["propset", "svn:mime-type", "application/octet-stream", "--", "first@.txt@"], at: fixture.root)
        let binary = try await fixture.client.fileReview(path: "first@.txt", at: fixture.root)
        #expect(binary.diff.contains("Cannot display: file marked as a binary type."))
        try Data([0, 1, 2, 255]).write(to: fixture.root.appendingPathComponent("first@.txt"))
        #expect(try await fixture.client.reviewSnapshot(path: "first@.txt", at: fixture.root) != binary.snapshot)
    }

    @Test func navigationMarksAndActualCommitScopeRemainSeparate() async throws {
        let fixture = try await makeFixture()
        let model = AppModel()
        model.executablePath = fixture.client.executable.path
        model.open(fixture.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let root = try #require(model.workingCopy?.root)
        defer { model.removeRecentPath(root.path) }
        model.selectedPaths = ["first@.txt", "second.txt"]
        model.message = "Keep the selected commit scope"
        model.beginReview()
        model.loadDiff()
        try await waitUntil { model.reviewState.displayed?.path == "first@.txt" }
        await model.markFocusedReview()
        #expect(model.reviewState.snapshots.count == 1)
        model.moveReview(by: 1)
        model.loadDiff()
        try await waitUntil { model.reviewState.displayed?.path == "second.txt" }
        #expect(model.selectedPaths == ["first@.txt", "second.txt"])
        model.prepareCommitSelected()
        try await waitUntil { !model.isBusy && model.commitPlan != nil }
        let plan = try #require(model.commitPlan)
        #expect(plan.items.count == 2)
        #expect(model.reviewedPaths(for: plan) == ["first@.txt"])
        #expect(model.canCommit)
        model.commitPlan = nil
        try Data("edited after review\n".utf8).write(to: root.appendingPathComponent("first@.txt"))
        try await model.refreshLocalState(at: root)
        #expect(model.reviewState.snapshots["first@.txt"] == nil)
        #expect(model.message == "Keep the selected commit scope")
        #expect(model.selectedPaths == ["first@.txt", "second.txt"])
    }

    @Test func staleDisplayedContentCannotBeMarkedAndCopiesDoNotShareMarks() async throws {
        let fixture = try await makeFixture()
        let model = AppModel()
        model.executablePath = fixture.client.executable.path
        model.open(fixture.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let root = try #require(model.workingCopy?.root)
        defer { model.removeRecentPath(root.path) }
        model.focusedPath = "first@.txt"
        model.loadDiff()
        try await waitUntil { model.reviewState.displayed != nil }
        try Data("unreviewed edit\n".utf8).write(to: root.appendingPathComponent("first@.txt"))
        await model.markFocusedReview()
        #expect(model.reviewState.snapshots.isEmpty)
        #expect(model.reviewState.error != nil)
        model.loadDiff()
        try await waitUntil { model.reviewState.displayed?.diff.contains("unreviewed edit") == true }
        await model.markFocusedReview()
        #expect(model.reviewState.snapshots.count == 1)
        let second = try await makeFixture()
        model.open(second.root)
        try await waitUntil { !model.isBusy && model.workingCopy?.root != root }
        let secondRoot = try #require(model.workingCopy?.root)
        #expect(model.reviewState.snapshots.isEmpty)
        model.open(root)
        try await waitUntil { !model.isBusy && model.workingCopy?.root == root }
        #expect(model.reviewState.snapshots.count == 1)
        model.removeRecentPath(secondRoot.path)
    }

    @Test func reviewIncludesImplicitChildrenOfCopiedDirectoriesWithoutSelectingThem() async throws {
        let fixture = try await makeFixture()
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("unchanged child\n".utf8).write(to: source.appendingPathComponent("child.txt"))
        _ = try await fixture.client.add(paths: ["source", "source/child.txt"], at: fixture.root)
        let initial = try await fixture.client.prepareCommit(paths: ["source", "source/child.txt"], message: "Directory fixture", at: fixture.root)
        _ = try await fixture.client.commit(initial)
        try await command(fixture.client.executable, ["copy", "--", "source", "copied"], at: fixture.root)
        let model = AppModel()
        model.executablePath = fixture.client.executable.path
        model.open(fixture.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let root = try #require(model.workingCopy?.root)
        defer { model.removeRecentPath(root.path) }
        model.selectedPaths = ["copied"]
        model.message = "Copy directory"
        model.prepareCommitSelected()
        try await waitUntil { !model.isBusy && model.commitPlan != nil }
        let plan = try #require(model.commitPlan)
        #expect(plan.items.contains { $0.path == "copied/child.txt" })
        model.beginReview(paths: plan.items.map(\.path))
        model.focusedPath = "copied/child.txt"
        model.loadDiff()
        try await waitUntil { model.reviewState.displayed?.path == "copied/child.txt" }
        await model.markFocusedReview()
        #expect(model.reviewedPaths(for: plan).contains("copied/child.txt"))
        #expect(model.selectedPaths == ["copied"])
        try await model.refreshLocalState(at: root)
        #expect(model.reviewState.snapshots["copied/child.txt"] != nil)
    }

    /// 所有写入只发生在新建且保留的本地临时仓库，不删除文件或使用业务服务器。
    private func makeFixture() async throws -> (root: URL, client: SVNClient) {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("mac-svn-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        try await command(svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), ["create", repository.path])
        let root = fixture.appendingPathComponent("中文 空格@副本")
        let client = SVNClient(executable: svn)
        _ = try await client.checkout(repository: repository.absoluteString, destination: root)
        for path in ["first@.txt", "second.txt"] {
            try Data("initial\n".utf8).write(to: root.appendingPathComponent(path))
        }
        _ = try await client.add(paths: ["first@.txt", "second.txt"], at: root)
        let plan = try await client.prepareCommit(paths: ["first@.txt", "second.txt"], message: "Initial review fixture", at: root)
        _ = try await client.commit(plan)
        try Data("first change\n".utf8).write(to: root.appendingPathComponent("first@.txt"))
        try Data("second change\n".utf8).write(to: root.appendingPathComponent("second.txt"))
        return (root, client)
    }

    private func command(_ executable: URL, _ arguments: [String], at root: URL? = nil) async throws {
        let output = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: root)
        try #require(output.exitCode == 0, "\(output.stderr)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "Timed out waiting for review state")
    }
}
