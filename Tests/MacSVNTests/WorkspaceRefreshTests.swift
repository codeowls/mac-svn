import Foundation
import Testing
import SVNCore
@testable import MacSVN

@MainActor
struct WorkspaceRefreshTests {
    @Test func coalescesRequestsAndDefersUntilForegroundOperationFinishes() async throws {
        let root = try makeDirectory()
        var reads = 0
        let controller = WorkspaceRefreshController(
            refresh: { _ in reads += 1 },
            reportFailure: { Issue.record("Unexpected refresh failure: \($0)") }
        )
        defer { controller.stop() }
        controller.watch(root)
        for _ in 0..<20 { controller.request() }
        try await waitUntil { reads == 1 }
        let activeRead = controller.suspend()
        await activeRead?.value
        controller.request()
        try await Task.sleep(for: .milliseconds(650))
        #expect(reads == 1)
        controller.resume()
        try await waitUntil { reads == 2 }
    }

    @Test func switchingCopyCancelsOldReadAndOnlyPublishesNewCopy() async throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        var started = false
        var published: [URL] = []
        let controller = WorkspaceRefreshController(
            refresh: { root in
                if root == first {
                    started = true
                    try await Task.sleep(for: .seconds(5))
                }
                try Task.checkCancellation()
                published.append(root)
            },
            reportFailure: { Issue.record("Unexpected refresh failure: \($0)") }
        )
        defer { controller.stop() }
        controller.watch(first)
        controller.request()
        try await waitUntil { started }
        controller.watch(second)
        controller.request()
        try await waitUntil { published == [second] }
        #expect(published == [second])
    }

    @Test func foregroundOperationWaitsForCancelledReadToFinish() async throws {
        let root = try makeDirectory()
        var read: CheckedContinuation<Void, Never>?
        var readFinished = false
        var published = false
        var writeStarted = false
        let controller = WorkspaceRefreshController(
            refresh: { _ in
                defer { readFinished = true }
                await withCheckedContinuation { read = $0 }
                try Task.checkCancellation()
                published = true
            },
            reportFailure: { Issue.record("Unexpected refresh failure: \($0)") }
        )
        defer { controller.stop() }
        controller.watch(root)
        controller.request()
        try await waitUntil { read != nil }
        let cancelledRead = controller.suspend()
        let foreground = Task { @MainActor in
            await cancelledRead?.value
            writeStarted = true
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(!writeStarted)
        read?.resume()
        await foreground.value
        #expect(readFinished)
        #expect(writeStarted)
        #expect(!published)
    }

    @Test func changesDuringReadTriggerAnotherReadAndFailuresAreReported() async throws {
        let root = try makeDirectory()
        var reads = 0
        var firstRead: CheckedContinuation<Void, Never>?
        var failure: String?
        let controller = WorkspaceRefreshController(
            refresh: { _ in
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { firstRead = $0 }
                } else {
                    throw SVNError("Refresh fixture failure")
                }
            },
            reportFailure: { failure = $0.localizedDescription }
        )
        defer { controller.stop() }
        controller.watch(root)
        controller.request()
        try await waitUntil { firstRead != nil }
        controller.request()
        firstRead?.resume()
        try await waitUntil { failure != nil }
        #expect(reads == 2)
        #expect(failure == "Refresh fixture failure")
    }

    /// 使用真实的本地 SVN 副本验证刷新边界，所有临时数据保留供检查。
    @Test func fileEventsRefreshStatusAndDiffWithoutResettingDraftOrHistory() async throws {
        let fixture = try await makeWorkingCopy()
        let model = AppModel()
        model.executablePath = fixture.client.executable.path
        model.open(fixture.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let root = try #require(model.workingCopy?.root)
        try Data("first local change\n".utf8).write(to: fixture.file)
        model.requestAutomaticRefresh()
        try await waitUntil { model.entries.contains { $0.path == "file@.txt" } }
        model.message = "Keep this commit draft"
        model.fileFilter = "file"
        model.selectedPaths = ["file@.txt"]
        model.loadHistory(path: "file@.txt")
        try await waitUntil { !model.isBusy && !model.logs.isEmpty }
        let revisions = model.logs.map(\.revision)
        let historyRevision = model.selectedHistoryRevision
        model.historyFilter.message = "Initial"
        model.result = "Keep this operation output"
        model.focusedPath = "file@.txt"
        try await model.refreshLocalState(at: root)
        #expect(model.diffText.contains("first local change"))

        // 第二次编辑只依赖实际 FSEvents，未主动发送刷新请求。
        try Data("second local change\n".utf8).write(to: fixture.file)
        try await waitUntil { model.diffText.contains("second local change") }
        #expect(model.message == "Keep this commit draft")
        #expect(model.selectedPaths == ["file@.txt"])
        #expect(model.fileFilter == "file")
        #expect(model.showHistory)
        #expect(model.historyPath == "file@.txt")
        #expect(model.historyFilter.message == "Initial")
        #expect(model.logs.map(\.revision) == revisions)
        #expect(model.selectedHistoryRevision == historyRevision)
        #expect(model.result == "Keep this operation output")
        #expect(model.automaticRefreshError == nil)

        // 内容恢复后清除无效勾选；提交说明和历史仍保留。
        try Data("initial\n".utf8).write(to: fixture.file)
        try await waitUntil { model.entries.isEmpty }
        #expect(model.selectedPaths.isEmpty)
        #expect(model.message == "Keep this commit draft")
        #expect(model.logs.map(\.revision) == revisions)
        model.removeRecentPath(root.path)
    }

    @Test func refreshFailurePreservesLastSnapshotAndShowsError() async throws {
        let fixture = try await makeWorkingCopy()
        let model = AppModel()
        model.executablePath = fixture.client.executable.path
        model.open(fixture.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let root = try #require(model.workingCopy?.root)
        model.message = "Keep draft after failure"
        let entries = model.entries
        model.executablePath = root.appendingPathComponent("nonexistent-svn").path
        model.requestAutomaticRefresh()
        try await waitUntil { model.automaticRefreshError != nil }
        #expect(model.entries == entries)
        #expect(model.message == "Keep draft after failure")
        #expect(model.workingCopy?.root == root)
        model.executablePath = fixture.client.executable.path
        model.requestAutomaticRefresh()
        try await waitUntil { model.automaticRefreshError == nil }
        model.removeRecentPath(root.path)
    }

    @Test func switchingWorkingCopyKeepsRepositoryAndDraftSeparate() async throws {
        let first = try await makeWorkingCopy()
        let second = try await makeWorkingCopy()
        let model = AppModel()
        model.executablePath = first.client.executable.path
        model.open(first.root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        let firstRoot = try #require(model.workingCopy?.root)
        let firstRepository = try #require(model.workingCopy?.repositoryURL)
        model.message = "First working-copy draft"
        model.requestAutomaticRefresh()

        model.open(second.root)
        try await waitUntil { !model.isBusy && model.workingCopy?.root != firstRoot }
        let secondRoot = try #require(model.workingCopy?.root)
        let secondInfo = try await second.client.workingCopy(at: second.root)
        #expect(model.workingCopy?.repositoryURL == secondInfo.repositoryURL)
        #expect(model.message.isEmpty)
        model.message = "Second working-copy draft"
        try await model.refreshLocalState(at: firstRoot)
        #expect(model.workingCopy?.root == secondRoot)
        #expect(model.workingCopy?.repositoryURL == secondInfo.repositoryURL)
        #expect(model.message == "Second working-copy draft")

        model.open(firstRoot)
        try await waitUntil { !model.isBusy && model.workingCopy?.root == firstRoot }
        #expect(model.workingCopy?.repositoryURL == firstRepository)
        #expect(model.message == "First working-copy draft")
        model.removeRecentPath(firstRoot.path)
        model.removeRecentPath(secondRoot.path)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-svn-auto-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeWorkingCopy() async throws -> (root: URL, file: URL, client: SVNClient) {
        let directory = try makeDirectory()
        let svn = try #require(SVNClient.discoverExecutable())
        let repository = directory.appendingPathComponent("repository")
        let output = try await ProcessRunner.run(
            executable: svn.deletingLastPathComponent().appendingPathComponent("svnadmin"),
            arguments: ["create", repository.path]
        )
        try #require(output.exitCode == 0, "\(output.stderr)")
        let root = directory.appendingPathComponent("中文 空格@副本")
        let client = SVNClient(executable: svn)
        _ = try await client.checkout(repository: repository.absoluteString, destination: root)
        let file = root.appendingPathComponent("file@.txt")
        try Data("initial\n".utf8).write(to: file)
        _ = try await client.add(paths: ["file@.txt"], at: root)
        let plan = try await client.prepareCommit(paths: ["file@.txt"], message: "Initial fixture", at: root)
        _ = try await client.commit(plan)
        return (root, file, client)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "Timed out waiting for workspace refresh")
    }
}
