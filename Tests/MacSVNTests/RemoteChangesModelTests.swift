import Foundation
import Testing
import SVNCore
@testable import MacSVN

@MainActor
struct RemoteChangesModelTests {
    @Test func previewAndRecheckLeaveWorkingCopyAndDraftUntouched() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("mac-svn-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        _ = try await run(svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), ["create", repository.path])
        let client = SVNClient(executable: svn)
        let root = fixture.appendingPathComponent("local")
        _ = try await client.checkout(repository: repository.absoluteString, destination: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await client.add(paths: ["file.txt"], at: root)
        _ = try await client.commit(try await client.prepareCommit(paths: ["file.txt"], message: "Initial fixture", at: root))
        let incoming = fixture.appendingPathComponent("incoming")
        _ = try await client.checkout(repository: repository.absoluteString, destination: incoming)
        try Data("remote\n".utf8).write(to: incoming.appendingPathComponent("file.txt"))
        try Data("new\n".utf8).write(to: incoming.appendingPathComponent("new.txt"))
        _ = try await client.add(paths: ["new.txt"], at: incoming)
        _ = try await client.commit(try await client.prepareCommit(paths: ["file.txt", "new.txt"], message: "Remote fixture", at: incoming))
        try Data("local draft\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let before = try await client.status(at: root)
        let revision = try await client.workingCopy(at: root).revision
        let model = AppModel()
        model.executablePath = svn.path
        model.open(root)
        try await waitUntil { !model.isBusy && model.workingCopy != nil }
        defer { model.removeRecentPath(root.path) }
        model.message = "Keep my draft"
        model.selectedPaths = ["file.txt"]
        model.inspectRemoteChanges()
        let state = try #require(model.remoteChangesState)
        try await waitUntil { !model.isBusy }
        let changes = try #require(state.changes)
        #expect(changes.revision == "2")
        #expect(changes.items.contains { $0.path == "file.txt" && $0.localOverlaps.map(\.path) == ["file.txt"] })
        #expect(changes.items.contains { $0.path == "new.txt" && $0.localOverlaps.isEmpty })
        #expect(model.message == "Keep my draft")
        #expect(model.selectedPaths == ["file.txt"])
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "local draft\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        #expect(try await client.workingCopy(at: root).revision == revision)
        #expect(try await client.status(at: root) == before)
        model.readRemoteChanges(state)
        #expect(state.changes == nil)
        #expect(state.isLoading)
        model.closeRemoteChanges(state)
        try await waitUntil { !model.isBusy }
        #expect(model.remoteChangesState == nil)
        #expect(state.changes == nil)
    }

    private func run(_ executable: URL, _ arguments: [String], at root: URL? = nil) async throws -> String {
        let output = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: root)
        try #require(output.exitCode == 0, "\(output.stderr)")
        return output.stdout
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }
}
