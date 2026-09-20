import Foundation
import Testing
@testable import SVNCore

struct FinderRequestTests {
    @Test func preservesSpecialPathsAndDeduplicates() throws {
        var url = URLComponents()
        url.scheme = "macsvn"
        url.host = "finder"
        let path = "/tmp/中文 空格@目录/文件 &?#.txt"
        url.queryItems = [URLQueryItem(name: "action", value: "commit")]
            + [path, path].map { URLQueryItem(name: "path", value: $0) }
        let request = try FinderRequest(url: #require(url.url))
        #expect(request.action == .commit)
        #expect(request.paths == [path])
    }

    @Test(arguments: [
        "macsvn://finder?action=delete&path=/tmp/file",
        "macsvn://finder?action=commit&action=update&path=/tmp/file",
        "macsvn://finder?action=update&path=relative",
        "macsvn://finder?action=update&path=/tmp/file&execute=true",
        "macsvn://finder?action=open&path=/tmp/file#fragment",
        "macsvn://user@finder?action=open&path=/tmp/file",
        "macsvn://finder:123?action=open&path=/tmp/file",
        "macsvn://finder?action=open",
        "macsvn://finder?action=open&path=/tmp/%00file"
    ])
    func rejectsMalformedRequests(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: SVNError.self) { try FinderRequest(url: url) }
    }

    @Test func directoryScopeUsesComponentBoundary() {
        #expect(FinderRequest.contains("src/file.swift", in: "src"))
        #expect(FinderRequest.contains("src", in: "src"))
        #expect(!FinderRequest.contains("src-other/file.swift", in: "src"))
        #expect(FinderRequest.contains("file.swift", in: "."))
    }
}

struct FinderSelectionTests {
    /// All writes stay in a new local repository; fixtures are retained for inspection.
    @Test func resolvesRealWorkingCopiesAndRejectsMixedSelection() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let svnadmin = svn.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-svn-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        try await run(svnadmin, ["create", repository.path])
        let first = fixture.appendingPathComponent("中文 空格@副本")
        let second = fixture.appendingPathComponent("second")
        try await run(svn, ["checkout", repository.absoluteString, first.path])
        try await run(svn, ["checkout", repository.absoluteString, second.path])
        let child = first.appendingPathComponent("untracked/文件 @.txt")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: child)
        let client = SVNClient(executable: svn)
        let resolved = try await client.resolveFinderSelection(request([child.path]))
        #expect(resolved.workingCopy.root.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
        #expect(resolved.relativePaths == ["untracked/文件 @.txt"])
        let root = try await client.resolveFinderSelection(request([first.path]))
        #expect(root.relativePaths == ["."])
        do {
            _ = try await client.resolveFinderSelection(request([first.path, second.path]))
            Issue.record("Mixed working copies must be rejected")
        } catch is SVNError {
            // Expected domain failure, not a command-launch or filesystem failure.
        }
        do {
            _ = try await client.resolveFinderSelection(request([fixture.path]))
            Issue.record("Non-working-copy selections must be rejected")
        } catch is SVNError {
        }
    }

    @Test func finderSelectionCommitAndHistoryPagination() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-svn-finder-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        try await run(svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), ["create", repository.path])
        let copy = fixture.appendingPathComponent("working-copy")
        try await run(svn, ["checkout", repository.absoluteString, copy.path])
        let selected = copy.appendingPathComponent("selected@.txt")
        let other = copy.appendingPathComponent("other.txt")
        try Data("initial\n".utf8).write(to: selected)
        try Data("other\n".utf8).write(to: other)
        try await run(svn, ["add", "--", selected.path + "@", other.path + "@"])
        try await run(svn, ["commit", "-m", "Initial fixture", "--", copy.path + "@"])
        try Data("selected change\n".utf8).write(to: selected)
        try Data("unselected change\n".utf8).write(to: other)
        let client = SVNClient(executable: svn)
        let selection = try await client.resolveFinderSelection(request([selected.path]))
        let entries = try await client.status(at: selection.workingCopy.root)
        let candidates = entries.filter { entry in
            selection.relativePaths.contains { FinderRequest.contains(entry.path, in: $0) }
        }
        #expect(candidates.map(\.path) == ["selected@.txt"])
        let plan = try await client.prepareCommit(paths: candidates.map(\.path), message: "Selected only", at: copy)
        _ = try await client.commit(plan)
        #expect(try await client.status(at: copy).map(\.path) == ["other.txt"])

        // Create enough real revisions to exercise the same cursor used by the Finder history form.
        for revision in 3...53 {
            try Data("revision \(revision)\n".utf8).write(to: selected)
            try await run(svn, ["commit", "-m", "History fixture \(revision)", "--", selected.path + "@"])
        }
        let first = try await client.historyPage(at: copy, path: "selected@.txt")
        #expect(first.entries.count == 50)
        let before = try #require(first.nextBeforeRevision)
        let second = try await client.historyPage(at: copy, path: "selected@.txt", beforeRevision: before)
        #expect(second.entries.count == 3)
        #expect(second.nextBeforeRevision == nil)
        let revisions = (first.entries + second.entries).map(\.revision)
        #expect(revisions.count == Set(revisions).count)
        #expect(revisions.first == "53")
        #expect(revisions.last == "1")
        #expect(try String(contentsOf: other, encoding: .utf8) == "unselected change\n")
    }

    private func request(_ paths: [String]) throws -> FinderRequest {
        var value = URLComponents()
        value.scheme = "macsvn"
        value.host = "finder"
        value.queryItems = [URLQueryItem(name: "action", value: "commit")]
            + paths.map { URLQueryItem(name: "path", value: $0) }
        return try FinderRequest(url: #require(value.url))
    }

    /// Keep blocking process waits off Swift Testing's cooperative executor.
    private func run(_ executable: URL, _ arguments: [String]) async throws {
        let output = try await ProcessRunner.run(executable: executable, arguments: arguments)
        try #require(output.exitCode == 0, "\(output.stderr)")
    }
}
