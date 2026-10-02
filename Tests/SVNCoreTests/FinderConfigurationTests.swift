import Foundation
import Testing
@testable import SVNCore

struct FinderConfigurationTests {
    @Test func preservesConfigurationAndSupportsDisablingAllRoots() throws {
        let value = FinderConfiguration(roots: ["/tmp/中文 空格@副本"], language: "en")
        #expect(try FinderConfiguration.decode(value.encoded()) == value)
        let disabled = FinderConfiguration(roots: [], language: "zh-Hans")
        #expect(try FinderConfiguration.decode(disabled.encoded()).roots.isEmpty)
    }

    @Test func rejectsInvalidDirectoryAndLanguage() throws {
        for value in [
            FinderConfiguration(roots: ["relative"], language: "en"),
            FinderConfiguration(roots: ["/tmp/\0name"], language: "en"),
            FinderConfiguration(roots: [], language: "unsupported")
        ] {
            #expect(throws: (any Error).self) { try FinderConfiguration.decode(value.encoded()) }
        }
    }

    @Test func badgeProtocolRejectsUnsafePathsAndExpiresSnapshots() throws {
        let request = FinderBadgeRequest(root: "/tmp/中文 @副本", paths: [".", "-目录 @/file.txt"])
        #expect(try FinderBadgeRequest.decode(request.encoded()).paths == request.paths)
        for path in ["", "../file", "dir/../file", "/file", "dir//file", ".svn/wc.db", "dir/.SVN/file", "bad\0name"] {
            let invalid = FinderBadgeRequest(root: "/tmp/copy", paths: [path])
            #expect(throws: (any Error).self) { try FinderBadgeRequest.decode(invalid.encoded()) }
        }
        let tooMany = FinderBadgeRequest(root: "/tmp/copy", paths: Array(repeating: "file", count: 129))
        #expect(throws: (any Error).self) { try FinderBadgeRequest.decode(tooMany.encoded()) }
        let scannedAt = Date(timeIntervalSince1970: 100)
        let response = FinderBadgeResponse(request: request, scannedAt: scannedAt, badges: [".": .modified])
        let decoded = try FinderBadgeResponse.decode(response.encoded())
        #expect(decoded.requestID == request.id)
        #expect(decoded.isFresh(at: scannedAt.addingTimeInterval(19)))
        #expect(!decoded.isFresh(at: scannedAt.addingTimeInterval(20)))
        #expect(!decoded.isFresh(at: scannedAt.addingTimeInterval(-1)))
        let roots = ["/tmp/copy", "/tmp/copy/nested"]
        let alias = FinderBadgeRequest.location(for: "/private/tmp/copy/中文 @file", roots: roots)
        #expect(alias?.root == "/tmp/copy")
        #expect(alias?.path == "中文 @file")
        #expect(FinderBadgeRequest.location(for: "/private/tmp/copy/nested/file", roots: roots)?.root == roots[1])
        #expect(FinderBadgeRequest.location(for: "/private/tmp/copy-other/file", roots: roots) == nil)
        #expect(FinderBadgeRequest.location(for: "/private/tmp/copy/.svn/wc.db", roots: roots) == nil)
        #expect(FinderBadgeRequest.monitoringPath(for: "/tmp/copy") == "/private/tmp/copy")
        #expect(FinderBadgeRequest.monitoringPath(for: "/private/tmp/copy") == "/private/tmp/copy")
        #expect(FinderBadgeRequest.monitoringPath(for: "/Users/copy") == "/Users/copy")
    }

    @Test func badgeAggregationDoesNotInventCleanStates() throws {
        let xml = """
        <status><target path=".">
        <entry path="."><wc-status item="normal" props="none"/></entry>
        <entry path="dir"><wc-status item="normal" props="none"/></entry>
        <entry path="dir/clean"><wc-status item="normal" props="none"/></entry>
        <entry path="dir/new"><wc-status item="added" props="none"/></entry>
        <entry path="dir/copied"><wc-status item="normal" props="none" copied="true"/></entry>
        <entry path="dir/props"><wc-status item="normal" props="modified"/></entry>
        <entry path="dir/conflict"><wc-status item="normal" props="none" tree-conflicted="true"/></entry>
        <entry path="ignored"><wc-status item="ignored" props="none"/></entry>
        <entry path="external"><wc-status item="external" props="none"/></entry>
        <entry path="external-file"><wc-status item="normal" props="normal" file-external="true"/></entry>
        <entry path="loose"><wc-status item="unversioned" props="none"/></entry>
        <entry path="missing"><wc-status item="missing" props="none"/></entry>
        <entry path=".svn"><wc-status item="ignored" props="none"/></entry>
        </target></status>
        """
        let snapshot = try FinderBadgeSnapshot(statusXML: xml, at: URL(fileURLWithPath: "/tmp"))
        #expect(snapshot.badges["."] == .conflicted)
        #expect(snapshot.badges["dir"] == .conflicted)
        #expect(snapshot.badges["dir/clean"] == .normal)
        #expect(snapshot.badges["dir/new"] == .added)
        #expect(snapshot.badges["dir/copied"] == .added)
        #expect(snapshot.badges["dir/props"] == .modified)
        #expect(snapshot.badges["loose"] == .unversioned)
        #expect(snapshot.badges["missing"] == .conflicted)
        for path in ["ignored", "external", "external-file", ".svn", "not-scanned", "loose/child"] {
            #expect(snapshot.badges[path] == nil)
        }
    }

    /// 真实 SVN 验证仅操作新建隔离样例，保留全部文件，不做测试目录清理。
    @Test func realBadgesCoverPropertiesDeletionAndUnversionedBoundaries() async throws {
        let svn = try #require(SVNClient.discoverExecutable())
        let fixture = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mac-svn-badges-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let repository = fixture.appendingPathComponent("repository")
        try await badgeCommand(svn.deletingLastPathComponent().appendingPathComponent("svnadmin"), ["create", repository.path])
        let copy = fixture.appendingPathComponent("中文 @副本")
        let client = SVNClient(executable: svn, globalIgnores: "*.cache")
        _ = try await client.checkout(repository: repository.absoluteString, destination: copy)
        let directory = "-目录 @"
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(directory), withIntermediateDirectories: true)
        for path in ["clean.txt", "removed.txt", directory + "/props.txt"] {
            try Data("initial\n".utf8).write(to: copy.appendingPathComponent(path))
        }
        try await badgeCommand(svn, ["add", "--force", "--", ".@"], at: copy)
        try await badgeCommand(svn, ["commit", "-m", "Badge fixture", "--", ".@"], at: copy)
        let clean = try await client.finderBadgeSnapshot(at: copy)
        #expect(clean.badges["."] == .normal)
        #expect(clean.badges["clean.txt"] == .normal)
        try Data("new\n".utf8).write(to: copy.appendingPathComponent("added.txt"))
        try await badgeCommand(svn, ["add", "--", "added.txt@"], at: copy)
        try await badgeCommand(svn, ["propset", "test:badge", "changed", "--", "./" + directory + "/props.txt@"], at: copy)
        try await badgeCommand(svn, ["delete", "--keep-local", "--", "removed.txt@"], at: copy)
        try Data("ignored\n".utf8).write(to: copy.appendingPathComponent("ignored.cache"))
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("loose"), withIntermediateDirectories: true)
        try Data("untracked\n".utf8).write(to: copy.appendingPathComponent("loose/child.txt"))
        _ = try await client.checkout(repository: repository.absoluteString, destination: copy.appendingPathComponent("nested"), depth: .empty)
        let snapshot = try await client.finderBadgeSnapshot(at: copy)
        #expect(snapshot.badges["."] == .modified)
        #expect(snapshot.badges[directory] == .modified)
        #expect(snapshot.badges[directory + "/props.txt"] == .modified)
        #expect(snapshot.badges["added.txt"] == .added)
        #expect(snapshot.badges["removed.txt"] == .modified)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("removed.txt").path))
        #expect(snapshot.badges["clean.txt"] == .normal)
        #expect(snapshot.badges["loose"] == .unversioned)
        for path in ["ignored.cache", "loose/child.txt", "nested", ".svn", "not-scanned"] {
            #expect(snapshot.badges[path] == nil)
        }
        let before = try await client.status(at: copy, includeIgnored: true)
        _ = try await client.finderBadgeSnapshot(at: copy)
        #expect(try await client.status(at: copy, includeIgnored: true) == before)
    }

    private func badgeCommand(_ executable: URL, _ arguments: [String], at directory: URL? = nil) async throws {
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: directory)
        try #require(result.exitCode == 0, "\(result.stderr)")
    }
}
