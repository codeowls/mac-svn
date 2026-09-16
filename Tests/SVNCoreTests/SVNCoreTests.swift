import Foundation
import Testing
@testable import SVNCore

@Suite("SVN XML 与路径语义")
struct XMLTests {
    @Test func propertiesAndConflicts() throws {
        let entries = try SVNXML.status("""
        <?xml version="1.0"?><status><target path=".">
          <entry path="中文 &amp; @ file.txt"><wc-status item="normal" props="modified" /></entry>
          <entry path="tree"><wc-status item="missing" props="none" tree-conflicted="true" /></entry>
          <entry path="property"><wc-status item="normal" props="conflicted" /></entry>
        </target></status>
        """)
        #expect(entries.count == 3)
        #expect(entries.first { $0.path == "中文 & @ file.txt" }?.canCommit == true)
        #expect(entries.first { $0.path == "tree" }?.isConflict == true)
        #expect(entries.first { $0.path == "property" }?.canCommit == false)
    }

    @Test func malformedXMLFails() {
        #expect(throws: (any Error).self) { try SVNXML.status("<status><entry>") }
        #expect(throws: (any Error).self) { try SVNXML.status("<info />") }
        #expect(throws: (any Error).self) { try SVNXML.status("<status><entry path='a'/></status>") }
    }

    @Test func multilineLogMessage() throws {
        let logs = try SVNXML.log("""
        <log><logentry revision="12"><author>tester</author><date>2026-09-16</date>
        <msg>第一行 &amp; 标记
        第二行</msg></logentry></log>
        """)
        #expect(logs.first?.message == "第一行 & 标记\n第二行")
    }
}

private struct Fixture {
    let root: URL
    let repository: URL
    let first: URL
    let second: URL
    let client: SVNClient

    static func create() async throws -> Fixture {
        guard let executable = SVNClient.discoverExecutable() else {
            throw SVNError("集成测试需要安装 SVN 1.14+ 和 svnadmin")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-svn-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repository")
        let admin = executable.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let output = try await ProcessRunner.run(executable: admin, arguments: ["create", repository.path])
        guard output.exitCode == 0 else { throw SVNError(output.stderr) }
        let client = SVNClient(executable: executable)
        let first = root.appendingPathComponent("working copy 一")
        let second = root.appendingPathComponent("working copy 二")
        _ = try await client.checkout(repository: repository.absoluteString, destination: first)
        _ = try await client.checkout(repository: repository.absoluteString, destination: second)
        return Fixture(root: root, repository: repository, first: first, second: second, client: client)
    }

    func write(_ path: String, _ content: String, in directory: URL? = nil) throws {
        try content.write(to: (directory ?? first).appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func svn(_ arguments: [String], in directory: URL? = nil) async throws {
        let output = try await ProcessRunner.run(
            executable: client.executable,
            arguments: ["--non-interactive"] + arguments,
            directory: directory ?? first
        )
        guard output.exitCode == 0 else { throw SVNError(output.stderr) }
    }
}

@Suite("真实本地 SVN 仓库集成")
struct IntegrationTests {
    @Test func selectedCommitAndSpecialFilenames() async throws {
        let f = try await Fixture.create()
        let special = "中文 @ & file.txt"
        try f.write(special, "one\n")
        try f.write("-option.txt", "two\n")
        _ = try await f.client.add(paths: [special, "-option.txt"], at: f.first)
        let diff = try await f.client.diff(path: special, at: f.first)
        #expect(diff.contains("+one"))
        _ = try await f.client.commit(paths: [special], message: "仅提交中文文件", at: f.first)
        let status = try await f.client.status(at: f.first)
        #expect(status.count == 1)
        #expect(status.first?.path == "-option.txt")
        #expect(status.first?.item == "added")
        _ = try await f.client.commit(paths: ["-option.txt"], message: "提交前导连字符文件", at: f.first)
        try f.write(special, "changed\n")
        let modifiedDiff = try await f.client.diff(path: special, at: f.first)
        #expect(modifiedDiff.contains("+changed"))
        let history = try await f.client.history(at: f.first)
        #expect(history.contains { $0.message == "仅提交中文文件" })
        _ = try await f.client.update(at: f.second)
        #expect(FileManager.default.fileExists(atPath: f.second.appendingPathComponent(special).path))
        #expect(FileManager.default.fileExists(atPath: f.second.appendingPathComponent("-option.txt").path))
        let copy = try await f.client.workingCopy(at: f.first)
        #expect(copy.root.resolvingSymlinksInPath() == f.first.resolvingSymlinksInPath())
    }

    @Test func directoryCommitDoesNotIncludeUnselectedChild() async throws {
        let f = try await Fixture.create()
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try f.write("folder/child.txt", "child\n")
        _ = try await f.client.add(paths: ["folder"], at: f.first)
        var status = try await f.client.status(at: f.first)
        #expect(status.first { $0.path == "folder/child.txt" }?.item == "unversioned")
        _ = try await f.client.add(paths: ["folder/child.txt"], at: f.first)
        _ = try await f.client.commit(paths: ["folder"], message: "仅目录", at: f.first)
        status = try await f.client.status(at: f.first)
        #expect(status.first { $0.path == "folder/child.txt" }?.item == "added")
        _ = try await f.client.commit(paths: ["folder/child.txt"], message: "添加子文件", at: f.first)
        _ = try await f.client.update(at: f.first)
        try await f.svn(["propset", "test:note", "changed", "folder"])
        try f.write("folder/child.txt", "unselected modification\n")
        _ = try await f.client.commit(paths: ["folder"], message: "仅目录属性", at: f.first)
        status = try await f.client.status(at: f.first)
        #expect(status.first { $0.path == "folder/child.txt" }?.item == "modified")
    }

    @Test func updateConflictBlocksCommit() async throws {
        let f = try await Fixture.create()
        try f.write("conflict.txt", "base\n")
        _ = try await f.client.add(paths: ["conflict.txt"], at: f.first)
        _ = try await f.client.commit(paths: ["conflict.txt"], message: "base", at: f.first)
        _ = try await f.client.update(at: f.second)
        try f.write("conflict.txt", "remote\n")
        _ = try await f.client.commit(paths: ["conflict.txt"], message: "remote", at: f.first)
        try f.write("conflict.txt", "local\n", in: f.second)
        _ = try await f.client.update(at: f.second)
        let status = try await f.client.status(at: f.second)
        #expect(status.first { $0.path == "conflict.txt" }?.isConflict == true)
        await #expect(throws: (any Error).self) {
            try await f.client.commit(paths: ["conflict.txt"], message: "must fail", at: f.second)
        }
    }

    @Test func staleSelectionAndOutsidePathFail() async throws {
        let f = try await Fixture.create()
        await #expect(throws: (any Error).self) {
            try await f.client.commit(paths: ["missing.txt"], message: "stale", at: f.first)
        }
        await #expect(throws: (any Error).self) {
            try await f.client.add(paths: ["../outside"], at: f.first)
        }
        await #expect(throws: (any Error).self) {
            try await f.client.checkout(repository: f.repository.absoluteString, destination: f.first)
        }
    }

    @Test func checkoutIntoExistingEmptyDirectoryAndRejectOccupiedTargets() async throws {
        let f = try await Fixture.create()
        try f.write("README.txt", "repository content\n")
        _ = try await f.client.add(paths: ["README.txt"], at: f.first)
        _ = try await f.client.commit(paths: ["README.txt"], message: "初始化检出内容", at: f.first)

        let destination = f.root.appendingPathComponent("existing empty folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        _ = try await f.client.checkout(repository: f.repository.absoluteString, destination: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("README.txt"), encoding: .utf8)
            == "repository content\n")
        let copy = try await f.client.workingCopy(at: destination)
        #expect(copy.root.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())

        let occupied = f.root.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try f.write(".keep", "local content", in: occupied)
        await #expect(throws: (any Error).self) {
            try await f.client.checkout(repository: f.repository.absoluteString, destination: occupied)
        }
        #expect(try String(contentsOf: occupied.appendingPathComponent(".keep"), encoding: .utf8) == "local content")
        #expect(try FileManager.default.contentsOfDirectory(atPath: occupied.path) == [".keep"])

        let file = occupied.appendingPathComponent(".keep")
        await #expect(throws: (any Error).self) {
            try await f.client.checkout(repository: f.repository.absoluteString, destination: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "local content")
    }

    @Test func copiedDirectoryCannotImplicitlyCommitChildren() async throws {
        let f = try await Fixture.create()
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("source"), withIntermediateDirectories: false)
        try f.write("source/file.txt", "content\n")
        _ = try await f.client.add(paths: ["source"], at: f.first)
        _ = try await f.client.add(paths: ["source/file.txt"], at: f.first)
        _ = try await f.client.commit(paths: ["source", "source/file.txt"], message: "initial", at: f.first)
        try await f.svn(["copy", "source", "copy"])
        await #expect(throws: (any Error).self) {
            try await f.client.commit(paths: ["copy"], message: "must not include children", at: f.first)
        }
        let history = try await f.client.history(at: f.first)
        #expect(history.count == 1)
    }
}

@Suite("子进程执行")
struct ProcessTests {
    @Test func streamsBeforeExitAndPreservesSplitUTF8() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("stream-ack-\(UUID().uuidString)")
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            // 子进程必须在退出前收到读取方的确认，否则以 9 退出，避免只在结束后回调也通过测试。
            return try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"""
                printf '\344'
                sleep 0.05
                printf '\270\255\346\226\207 first\n'
                printf 'warning\n' >&2
                i=0
                while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do
                    sleep 0.02
                    i=$((i + 1))
                done
                if [ ! -f "$1" ]; then
                    exit 9
                fi
                printf 'done'
                exit 7
                """#, "stream-test", marker.path],
                onOutput: { continuation.yield($0) }
            )
        }
        var received = ""
        for await text in stream {
            received += text
            if text.contains("中文 first\n") {
                try Data().write(to: marker)
            }
        }
        let output = try await task.value
        #expect(output.exitCode == 7)
        #expect(output.stdout == "中文 first\ndone")
        #expect(output.stderr == "warning\n")
        #expect(received.contains("中文 first\n"))
        #expect(received.contains("warning\n"))
        #expect(received.contains("done"))
        #expect(!received.contains("�"))
    }

    @Test func cancellationStopsProcess() async throws {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'started\\n'; exec /bin/sleep 20"],
                onOutput: { continuation.yield($0) }
            )
        }
        var received = ""
        for await text in stream {
            received += text
            task.cancel()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(received == "started\n")
    }

    @Test func drainsBothPipesAndReportsExitCode() async throws {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reader = Task {
            var lines: [String] = []
            for await text in stream {
                lines += text.split(separator: "\n").map(String.init)
            }
            return lines
        }
        // Fixed test script only; production SVN invocation never uses a shell.
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 6000 ]; do echo stdout; echo stderr >&2; i=$((i + 1)); done; exit 7"],
            onOutput: { continuation.yield($0) }
        )
        continuation.finish()
        let lines = await reader.value
        #expect(output.exitCode == 7)
        #expect(output.stdout.split(separator: "\n").count == 6000)
        #expect(output.stderr.split(separator: "\n").count == 6000)
        #expect(lines.filter { $0 == "stdout" }.count == 6000)
        #expect(lines.filter { $0 == "stderr" }.count == 6000)
    }
}

@Suite("远端分支浏览与检出")
struct RepositoryTests {
    @Test func directoryListingAndInvalidResponses() throws {
        let entries = try SVNXML.repositoryEntries("""
        <lists><list path="https://example.test/project">
        <entry kind="file"><name>README &amp; notes</name><commit revision="3"><author>tester</author></commit></entry>
        <entry kind="dir"><name>branches</name><commit revision="2"><author>tester</author></commit></entry>
        </list></lists>
        """)
        #expect(entries.map(\.name) == ["branches", "README & notes"])
        #expect(entries.first?.isDirectory == true)
        #expect(try SVNXML.repositoryEntries("<lists><list path='x'/></lists>").isEmpty)
        #expect(throws: (any Error).self) { try SVNXML.repositoryEntries("<info/>") }
        #expect(throws: (any Error).self) {
            try SVNXML.repositoryEntries("<lists><list><entry kind='dir'/></list></lists>")
        }
        #expect(throws: (any Error).self) {
            try SVNXML.repositoryInfo("<info><entry kind='file'><url>file:///a</url></entry></info>")
        }
    }

    @Test func invalidURLsAndEncodedBranchNames() async throws {
        let f = try await Fixture.create()
        for invalid in ["/local/path", "https://", "https://user:password@example.test/repo",
                        "https://example.test/repo?secret=1", "https://example.test/repo#branch"] {
            await #expect(throws: (any Error).self) { try await f.client.listRepository(invalid) }
        }
        let child = try SVNClient.childRepositoryURL(parent: "https://example.test/branches", name: "中文 @ # &")
        #expect(URL(string: child)?.lastPathComponent == "中文 @ # &")
        #expect(URLComponents(string: child)?.fragment == nil)
        #expect(throws: (any Error).self) {
            try SVNClient.childRepositoryURL(parent: "https://example.test/repo", name: "../outside")
        }
    }

    @Test func browseBranchesAndCheckoutOnlySelectedDirectory() async throws {
        let f = try await Fixture.create()
        let trunk = try SVNClient.childRepositoryURL(parent: f.repository.absoluteString, name: "trunk")
        let branches = try SVNClient.childRepositoryURL(parent: f.repository.absoluteString, name: "branches")
        try await f.svn(["mkdir", trunk + "@", branches + "@", "-m", "创建布局"])
        let source = f.root.appendingPathComponent("trunk-copy")
        _ = try await f.client.checkout(repository: trunk, destination: source)
        try f.write("README.txt", "branch content\n", in: source)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("资料/子目录/空目录"), withIntermediateDirectories: true
        )
        try f.write("资料/子目录/中文 @ 文件.txt", "nested content\n", in: source)
        let paths = ["README.txt", "资料", "资料/子目录", "资料/子目录/空目录", "资料/子目录/中文 @ 文件.txt"]
        _ = try await f.client.add(paths: paths, at: source)
        try await f.svn(["propset", "svn:externals", "^/branches external-copy", "."], in: source)
        _ = try await f.client.commit(paths: ["."] + paths, message: "初始化", at: source)
        let branch = try SVNClient.childRepositoryURL(parent: branches, name: "发布 @ 中文")
        try await f.svn(["copy", trunk + "@", branch + "@", "-m", "创建分支"])
        let rootEntries = try await f.client.listRepository(f.repository.absoluteString)
        #expect(Set(rootEntries.map(\.name)) == ["trunk", "branches"])
        let branchEntries = try await f.client.listRepository(branches)
        #expect(branchEntries.first?.name == "发布 @ 中文")
        let info = try await f.client.repositoryLocation(branch)
        #expect(URL(string: info.url)?.lastPathComponent == "发布 @ 中文")
        let destination = f.root.appendingPathComponent("selected-branch")
        _ = try await f.client.checkout(repository: info.url, destination: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("README.txt"), encoding: .utf8) == "branch content\n")
        #expect(try String(
            contentsOf: destination.appendingPathComponent("资料/子目录/中文 @ 文件.txt"), encoding: .utf8
        ) == "nested content\n")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("资料/子目录/空目录").path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("external-copy").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("trunk").path))
        let copy = try await f.client.workingCopy(at: destination)
        #expect(copy.repositoryURL == info.url)
        await #expect(throws: (any Error).self) {
            try await f.client.repositoryLocation(branches + "/does-not-exist")
        }
    }
}
