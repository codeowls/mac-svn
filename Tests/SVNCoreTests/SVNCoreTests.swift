import Foundation
import Testing
@testable import SVNCore

@Suite("SVN XML 与路径语义")
struct XMLTests {
    @Test func globalIgnorePatternsKeepSVNGlobSemantics() throws {
        let patterns = try SVNConfiguration.normalizeIgnorePatterns(" .idea\n*.iml\t#*#  .idea  .*.swp \r\n")
        #expect(patterns == ".idea *.iml #*# .*.swp")
        #expect(try SVNConfiguration.normalizeIgnorePatterns(" \n\t") == "")
        #expect(throws: SVNError.self) {
            try SVNConfiguration.normalizeIgnorePatterns("*.tmp\0*.log")
        }
        #expect(throws: SVNError.self) {
            try SVNConfiguration.executableURL(for: "/usr/bin")
        }
        #expect(throws: SVNError.self) {
            try SVNConfiguration.executableURL(for: "svn")
        }
    }

    @Test func executableTestChecksRealVersionAndRejectsNonSVN() async throws {
        let executable = try #require(SVNClient.discoverExecutable())
        let version = try await SVNClient(executable: executable).version()
        #expect(version.split(separator: ".").count >= 3)
        await #expect(throws: SVNError.self) {
            try await SVNClient(executable: URL(fileURLWithPath: "/usr/bin/true")).version()
        }
    }

    @Test func diffLineNumbersAndSplitAlignment() {
        let diff = UnifiedDiff("""
        --- sample.txt (revision 1)
        +++ sample.txt (working copy)
        @@ -3,3 +3,4 @@
         context
        -old
        +new
        +extra
         end
        @@ -20 +21 @@
        -last
        +final
        \\ No newline at end of file
        """)
        #expect(diff.additions == 3)
        #expect(diff.deletions == 2)
        #expect(diff.hunkIDs == [2, 8])
        #expect(diff.lines[3].oldNumber == 3)
        #expect(diff.lines[5].newNumber == 4)
        #expect(diff.lines[7].oldNumber == 5)
        #expect(diff.lines[7].newNumber == 6)
        #expect(diff.lines[10].newNumber == 21)
        let replacement = diff.splitRows.first { $0.left?.text == "-old" }
        #expect(replacement?.right?.text == "+new")
        #expect(diff.splitRows.first { $0.right?.text == "+extra" }?.left == nil)
    }

    @Test func diffSeparatesPropertiesAndHeaderLikeContent() {
        let diff = UnifiedDiff("""
        --- sample
        +++ sample
        @@ -1 +1 @@
        --- old content
        +++ new content
        Property changes on: sample
        ___________________________________________________________________
        Modified: svn:keywords
        ## -1 +1 ##
        -Id
        +Date
        """)
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
        #expect(diff.lines[3].oldNumber == 1)
        #expect(diff.lines.last?.newNumber == nil)
        #expect(diff.lines.last?.kind == .metadata)
    }

    @Test func diffHandlesEmptyRangesAndBinaryNotice() {
        let added = UnifiedDiff("@@ -0,0 +1,2 @@\n+one\n+two\n")
        #expect(added.additions == 2)
        #expect(added.lines[1].oldNumber == nil)
        #expect(added.lines[2].newNumber == 2)
        let removed = UnifiedDiff("@@ -1,2 +0,0 @@\n-one\n-two\n")
        #expect(removed.deletions == 2)
        #expect(removed.lines[2].oldNumber == 2)
        #expect(removed.lines[2].newNumber == nil)
        let binary = UnifiedDiff("Cannot display: file marked as a binary type.\nsvn:mime-type = application/octet-stream\n")
        #expect(binary.additions == 0)
        #expect(binary.hunkIDs.isEmpty)
        #expect(binary.lines.count == 2)
    }

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
        #expect(logs.first?.changedPaths.isEmpty == true)
    }

    @Test func historyChangedPathsPreserveActionsAndCopySource() throws {
        let logs = try SVNXML.log("""
        <log><logentry revision="12"><paths>
          <path action="A" kind="file" copyfrom-path="/旧目录/a &amp; b.txt" copyfrom-rev="9" text-mods="true" prop-mods="false">/新目录/中文 @ 文件.txt</path>
          <path action="M" kind="dir" text-mods="false" prop-mods="true">/属性目录</path>
          <path action="D" kind="file">/已删除.txt</path>
          <path action="R">/替换.txt</path>
        </paths><msg>变更记录</msg></logentry></log>
        """)
        let paths = try #require(logs.first?.changedPaths)
        #expect(paths.count == 4)
        let copied = try #require(paths.first { $0.action == "A" })
        #expect(copied.path == "/新目录/中文 @ 文件.txt")
        #expect(copied.copyFromPath == "/旧目录/a & b.txt")
        #expect(copied.copyFromRevision == "9")
        #expect(copied.label == "新增 · 复制")
        #expect(paths.first { $0.action == "M" }?.label == "属性修改")
        #expect(paths.first { $0.action == "D" }?.label == "删除")
        #expect(paths.first { $0.action == "R" }?.label == "替换")
        #expect(paths.first { $0.action == "R" }?.textModified == nil)
        #expect(throws: SVNError.self) {
            try SVNXML.log("<log><logentry revision='1'><paths><path>/broken</path></paths></logentry></log>")
        }
    }

    @Test func historyAuthenticationErrorKeepsDiagnosticsSeparate() {
        let partialXML = "<?xml version=\"1.0\"?><log>"
        let stderr = "svn: E170013: Unable to connect\nsvn: E170001: Can't get username or password\n"
        let error = SVNError(output: CommandOutput(stdout: partialXML, stderr: stderr, exitCode: 1), xmlOutput: true)
        #expect(error.requiresAuthentication)
        #expect(error.message.contains("请登录仓库"))
        #expect(!error.message.contains(partialXML))
        #expect(error.diagnostic.contains(partialXML))
        #expect(error.diagnostic.contains(stderr))
        let connection = SVNError(
            output: CommandOutput(stdout: partialXML, stderr: "svn: E170013: Unable to connect\nsvn: E000061: Connection refused", exitCode: 1),
            xmlOutput: true
        )
        #expect(!connection.requiresAuthentication)
        #expect(connection.message.contains("Connection refused"))
    }

    @Test func historyFiltersCombineFieldsAndKeepMultilineMessages() throws {
        let logs = try SVNXML.log("""
        <log>
          <logentry revision="3"><author>Alice</author><msg>修复界面
        第二行 Details</msg><paths><path action="M">/目录/中文 @ File.txt</path></paths></logentry>
          <logentry revision="2"><author>Bob</author><msg>修复界面</msg><paths><path action="M">/other.txt</path></paths></logentry>
          <logentry revision="1"><msg>初始化</msg></logentry>
        </log>
        """)
        var filter = HistoryFilter()
        #expect(logs.filter(filter.matches).count == 3)
        filter.author = " alice "
        filter.message = "details"
        filter.path = "中文 @ file"
        #expect(logs.filter(filter.matches).map(\.revision) == ["3"])
        filter.author = "Bob"
        #expect(logs.filter(filter.matches).isEmpty)
        filter.author = " "
        filter.message = "\n"
        filter.path = " "
        #expect(filter.isEmpty)
        #expect(logs.filter(filter.matches).count == 3)
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
    @Test func historicalDiffPreservesRevisionSemanticsAndLocalChanges() async throws {
        let f = try await Fixture.create()
        let name = "-中文 @ & file.txt"
        try f.write(name, "original\n")
        try f.write("deleted.txt", "delete me\n")
        try f.write("replaced.txt", "old node\n")
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try f.write("folder/child.txt", "child\n")
        try Data([0, 1, 2]).write(to: f.first.appendingPathComponent("binary.dat"))
        try await f.svn(["add", "--force", "--", "."])
        try await f.svn(["propset", "svn:mime-type", "application/octet-stream", "binary.dat"])
        try await f.svn(["commit", "--message", "initial"])
        let initial = try #require(try await f.client.history(at: f.first).first)
        let added = try #require(initial.changedPaths.first { $0.path == "/" + name })
        let addition = try await f.client.historicalDiff(change: added, revision: "1", at: f.first)
        #expect(addition.oldLabel.contains("r0（不存在）"))
        #expect(addition.text.contains("+original"))

        try f.write(name, "modified\n")
        try f.write("folder/child.txt", "changed child\n")
        try await f.svn(["propset", "test:note", "directory property", "folder"])
        try Data([0, 3, 4]).write(to: f.first.appendingPathComponent("binary.dat"))
        try await f.svn(["delete", "--keep-local", "replaced.txt"])
        try f.write("replaced.txt", "replacement\n")
        try await f.svn(["add", "replaced.txt"])
        try await f.svn(["copy", "--", "./\(name)@", "./copy @.txt@"])
        try await f.svn(["commit", "--message", "modify, copy and replace"])
        let changed = try #require(try await f.client.history(at: f.first).first)
        let modified = try #require(changed.changedPaths.first { $0.path == "/" + name })
        let copied = try #require(changed.changedPaths.first { $0.path == "/copy @.txt" })
        let replaced = try #require(changed.changedPaths.first { $0.path == "/replaced.txt" })
        let directory = try #require(changed.changedPaths.first { $0.path == "/folder" })
        let binary = try #require(changed.changedPaths.first { $0.path == "/binary.dat" })
        try f.write(name, "uncommitted local content\n")
        let before = try await f.client.status(at: f.first)
        let modification = try await f.client.historicalDiff(change: modified, revision: "2", at: f.first)
        #expect(modification.text.contains("-original") && modification.text.contains("+modified"))
        #expect(!modification.text.contains("uncommitted"))
        let copy = try await f.client.historicalDiff(change: copied, revision: "2", at: f.first)
        #expect(copy.oldLabel.contains("r1（复制来源）"))
        #expect(copy.text.contains("-original") && copy.text.contains("+modified"))
        let replacement = try await f.client.historicalDiff(change: replaced, revision: "2", at: f.first)
        #expect(replacement.text.contains("-old node") && replacement.text.contains("+replacement"))
        let property = try await f.client.historicalDiff(change: directory, revision: "2", at: f.first)
        #expect(property.text.contains("test:note"))
        #expect(!property.text.contains("changed child"))
        let binaryDiff = try await f.client.historicalDiff(change: binary, revision: "2", at: f.first)
        #expect(binaryDiff.text.contains("Cannot display") && binaryDiff.text.contains("binary"))
        #expect(try await f.client.status(at: f.first) == before)

        try await f.svn(["delete", "--keep-local", "deleted.txt"])
        try await f.svn(["commit", "--message", "delete", "deleted.txt"])
        let deletionLog = try #require(try await f.client.history(at: f.first).first)
        let deleted = try #require(deletionLog.changedPaths.first)
        let deletion = try await f.client.historicalDiff(change: deleted, revision: "3", at: f.first)
        #expect(deletion.newLabel.contains("已删除"))
        #expect(deletion.text.contains("-delete me"))
        #expect(try String(contentsOf: f.first.appendingPathComponent(name), encoding: .utf8) == "uncommitted local content\n")
    }

    @Test func revertChecksSnapshotAndKeepsUnselectedChanges() async throws {
        let f = try await Fixture.create()
        let name = "-还原 @ 文件.txt"
        try f.write(name, "base\n")
        try f.write("keep.txt", "base\n")
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try f.write("folder/child.txt", "base\n")
        try await f.svn(["add", "--force", "--", "."])
        try await f.svn(["commit", "--message", "initial"])
        try f.write(name, "reviewed content\n")
        try f.write("keep.txt", "keep local\n")
        let stale = try await f.client.prepareRevert(paths: [name], at: f.first)
        #expect(stale.items.first?.preview.contains("+reviewed content") == true)
        try f.write(name, "changed after review\n")
        await #expect(throws: SVNError.self) { try await f.client.revert(stale) }
        #expect(try String(contentsOf: f.first.appendingPathComponent(name), encoding: .utf8) == "changed after review\n")
        let plan = try await f.client.prepareRevert(paths: [name], at: f.first)
        _ = try await f.client.revert(plan)
        #expect(try String(contentsOf: f.first.appendingPathComponent(name), encoding: .utf8) == "base\n")
        #expect(try String(contentsOf: f.first.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep local\n")

        try f.write("folder/child.txt", "keep child\n")
        try await f.svn(["propset", "test:note", "discard", "folder"])
        let directory = try await f.client.prepareRevert(paths: ["folder"], at: f.first)
        #expect(directory.items.first?.isDirectory == true)
        _ = try await f.client.revert(directory)
        #expect(try String(contentsOf: f.first.appendingPathComponent("folder/child.txt"), encoding: .utf8) == "keep child\n")
        #expect(try await f.client.status(at: f.first).contains { $0.path == "folder" } == false)

        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("new folder"), withIntermediateDirectories: false)
        try f.write("new folder/child.txt", "keep added file\n")
        try await f.svn(["add", "new folder"])
        await #expect(throws: SVNError.self) {
            try await f.client.prepareRevert(paths: ["new folder"], at: f.first)
        }
        let addition = try await f.client.prepareRevert(paths: ["new folder", "new folder/child.txt"], at: f.first)
        _ = try await f.client.revert(addition)
        #expect(try String(contentsOf: f.first.appendingPathComponent("new folder/child.txt"), encoding: .utf8) == "keep added file\n")
        #expect(try await f.client.status(at: f.first).first { $0.path == "new folder" }?.item == "unversioned")
    }

    @Test func revertRestoresMissingDeletedReplacedAndRemovesCopiedFile() async throws {
        let f = try await Fixture.create()
        for name in ["missing.txt", "deleted.txt", "replaced.txt", "source.txt"] {
            try f.write(name, "base \(name)\n")
        }
        try await f.svn(["add", "--force", "--", "."])
        try await f.svn(["commit", "--message", "initial"])
        try FileManager.default.removeItem(at: f.first.appendingPathComponent("missing.txt"))
        try await f.svn(["delete", "deleted.txt"])
        try await f.svn(["delete", "--keep-local", "replaced.txt"])
        try f.write("replaced.txt", "replacement\n")
        try await f.svn(["add", "replaced.txt"])
        try await f.svn(["copy", "source.txt", "copied.txt"])
        try f.write("copied.txt", "copy modifications\n")
        let plan = try await f.client.prepareRevert(
            paths: ["missing.txt", "deleted.txt", "replaced.txt", "copied.txt"], at: f.first
        )
        #expect(plan.items.first { $0.entry.path == "copied.txt" }?.effect.contains("删除") == true)
        _ = try await f.client.revert(plan)
        for name in ["missing.txt", "deleted.txt", "replaced.txt", "source.txt"] {
            #expect(try String(contentsOf: f.first.appendingPathComponent(name), encoding: .utf8) == "base \(name)\n")
        }
        #expect(!FileManager.default.fileExists(atPath: f.first.appendingPathComponent("copied.txt").path))
        #expect(try await f.client.status(at: f.first).isEmpty)
    }

    @Test func revertRejectsChangedBinaryPropertiesAndStructuralDirectories() async throws {
        let f = try await Fixture.create()
        try Data([0, 1, 2]).write(to: f.first.appendingPathComponent("binary.dat"))
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try f.write("folder/child.txt", "base\n")
        try await f.svn(["add", "--force", "--", "."])
        try await f.svn(["propset", "svn:mime-type", "application/octet-stream", "binary.dat"])
        try await f.svn(["commit", "--message", "initial"])
        try Data([0, 3, 4]).write(to: f.first.appendingPathComponent("binary.dat"))
        let binary = try await f.client.prepareRevert(paths: ["binary.dat"], at: f.first)
        try Data([0, 5, 6]).write(to: f.first.appendingPathComponent("binary.dat"))
        await #expect(throws: SVNError.self) { try await f.client.revert(binary) }
        #expect(try Data(contentsOf: f.first.appendingPathComponent("binary.dat")) == Data([0, 5, 6]))
        let property = try await f.client.prepareRevert(paths: ["binary.dat"], at: f.first)
        try await f.svn(["propset", "test:note", "after confirmation", "binary.dat"])
        await #expect(throws: SVNError.self) { try await f.client.revert(property) }
        try await f.svn(["copy", "folder", "copied-folder"])
        await #expect(throws: SVNError.self) {
            try await f.client.prepareRevert(paths: ["copied-folder"], at: f.first)
        }
        try await f.svn(["delete", "folder"])
        await #expect(throws: SVNError.self) {
            try await f.client.prepareRevert(paths: ["folder"], at: f.first)
        }
        await #expect(throws: SVNError.self) {
            try await f.client.prepareRevert(paths: ["../outside"], at: f.first)
        }
    }

    @Test func commitAndUpdateStreamRealSVNOutput() async throws {
        let f = try await Fixture.create()
        try f.write("stream.txt", "first\n")
        _ = try await f.client.add(paths: ["stream.txt"], at: f.first)
        let (commitStream, commitContinuation) = AsyncStream<String>.makeStream()
        let committing = Task {
            defer { commitContinuation.finish() }
            return try await f.client.commit(paths: ["stream.txt"], message: "streamed commit", at: f.first) {
                commitContinuation.yield($0)
            }
        }
        var commitOutput = ""
        for await text in commitStream { commitOutput += text }
        let commitResult = try await committing.value
        #expect(commitOutput == commitResult)
        #expect(commitOutput.contains("Committed revision 1"))

        let (updateStream, updateContinuation) = AsyncStream<String>.makeStream()
        let updating = Task {
            defer { updateContinuation.finish() }
            return try await f.client.update(at: f.second) { updateContinuation.yield($0) }
        }
        var updateOutput = ""
        for await text in updateStream { updateOutput += text }
        let updateResult = try await updating.value
        #expect(updateOutput == updateResult)
        #expect(updateOutput.contains("stream.txt") && updateOutput.contains("revision 1"))
        #expect(try String(contentsOf: f.second.appendingPathComponent("stream.txt"), encoding: .utf8) == "first\n")
    }

    @Test func historyPagesBeyondFiftyAndKeepsCursorWhenHeadChanges() async throws {
        let f = try await Fixture.create()
        try f.write("history.txt", "1\n")
        _ = try await f.client.add(paths: ["history.txt"], at: f.first)
        for revision in 1...55 {
            try f.write("history.txt", "\(revision)\n")
            try await f.svn(["commit", "--message", "历史 \(revision)"])
        }
        let first = try await f.client.historyPage(at: f.first)
        #expect(first.entries.map(\.revision) == (6...55).reversed().map(String.init))
        #expect(first.nextBeforeRevision == 6)

        try f.write("history.txt", "56\n")
        try await f.svn(["commit", "--message", "分页期间新增"])
        let second = try await f.client.historyPage(at: f.first, beforeRevision: first.nextBeforeRevision)
        #expect(second.entries.map(\.revision) == ["5", "4", "3", "2", "1"])
        #expect(second.nextBeforeRevision == nil)
        #expect(Set((first.entries + second.entries).map(\.revision)).count == 55)
        let reloaded = try await f.client.historyPage(at: f.first)
        #expect(reloaded.entries.first?.revision == "56")
        #expect(try await f.client.status(at: f.first).isEmpty)
    }

    @Test func fileHistoryPagesFollowCopiesAndSkipUnrelatedRevisions() async throws {
        let f = try await Fixture.create()
        let source = "中文 @ & file.txt"
        let copied = "-复制 @ file.txt"
        try f.write(source, "original\n")
        _ = try await f.client.add(paths: [source], at: f.first)
        try await f.svn(["commit", "--message", "原始文件"])
        try f.write("other.txt", "unrelated\n")
        _ = try await f.client.add(paths: ["other.txt"], at: f.first)
        try await f.svn(["commit", "--message", "无关文件"])
        try f.write(source, "modified\n")
        try await f.svn(["commit", "--message", "修改源文件"])
        try await f.svn(["copy", "--", "./\(source)@", "./\(copied)@"])
        try await f.svn(["commit", "--message", "保留历史复制"])
        try f.write(copied, "local uncommitted\n")
        let before = try await f.client.status(at: f.first)

        let first = try await f.client.historyPage(at: f.first, path: copied, pageSize: 2)
        #expect(first.entries.map(\.revision) == ["4", "3"])
        #expect(first.entries.first?.changedPaths.first?.copyFromPath == "/" + source)
        let second = try await f.client.historyPage(
            at: f.first, path: copied, beforeRevision: first.nextBeforeRevision, pageSize: 2
        )
        #expect(second.entries.map(\.revision) == ["1"])
        #expect(second.nextBeforeRevision == nil)
        let exactPage = try await f.client.historyPage(at: f.first, path: source, pageSize: 2)
        #expect(exactPage.entries.map(\.revision) == ["3", "1"])
        #expect(exactPage.nextBeforeRevision == nil)
        #expect(try await f.client.status(at: f.first) == before)
        #expect(try String(contentsOf: f.first.appendingPathComponent(copied), encoding: .utf8) == "local uncommitted\n")
        await #expect(throws: SVNError.self) {
            try await f.client.historyPage(at: f.first, path: "../outside")
        }
        await #expect(throws: SVNError.self) {
            try await f.client.historyPage(at: f.first, path: "missing.txt")
        }
        let nested = f.first.appendingPathComponent("nested-copy")
        _ = try await f.client.checkout(repository: f.repository.absoluteString, destination: nested)
        await #expect(throws: SVNError.self) {
            try await f.client.historyPage(at: f.first, path: "nested-copy/\(copied)")
        }
    }

    @Test func globalIgnoresHideOnlyUnversionedItems() async throws {
        let f = try await Fixture.create()
        let baseline = SVNClient(executable: f.client.executable, globalIgnores: "")
        try f.write("tracked.iml", "base\n")
        _ = try await baseline.add(paths: ["tracked.iml"], at: f.first)
        _ = try await baseline.commit(paths: ["tracked.iml"], message: "受控文件", at: f.first)
        try f.write("tracked.iml", "modified\n")
        try f.write("project.iml", "local project\n")
        try f.write("#backup#", "backup\n")
        try f.write("keep.txt", "keep\n")
        try FileManager.default.createDirectory(at: f.first.appendingPathComponent(".idea"), withIntermediateDirectories: false)
        try f.write(".idea/workspace.xml", "local settings\n")

        let client = SVNClient(executable: f.client.executable, globalIgnores: ".idea\n*.iml #*#")
        let hidden = try await client.status(at: f.first)
        #expect(Set(hidden.map(\.path)) == ["tracked.iml", "keep.txt"])
        #expect(hidden.first { $0.path == "tracked.iml" }?.item == "modified")
        let shown = try await client.status(at: f.first, includeIgnored: true)
        #expect(shown.first { $0.path == "project.iml" }?.item == "ignored")
        #expect(shown.first { $0.path == ".idea" }?.item == "ignored")
        #expect(shown.first { $0.path == "#backup#" }?.item == "ignored")
        #expect(!shown.contains { $0.path == ".svn" })

        let unchanged = try await baseline.status(at: f.first)
        #expect(unchanged.first { $0.path == "project.iml" }?.item == "unversioned")
        #expect(unchanged.first { $0.path == "keep.txt" }?.item == "unversioned")
        #expect(try String(contentsOf: f.first.appendingPathComponent(".idea/workspace.xml"), encoding: .utf8) == "local settings\n")

        _ = try await client.commit(paths: ["tracked.iml"], message: "忽略规则不影响受控修改", at: f.first)
        let history = try await client.history(at: f.first)
        #expect(history.first?.changedPaths.map(\.path) == ["/tracked.iml"])
    }

    @Test func globalIgnoreOverrideIsPerClientAndKeepsDirectoryProperties() async throws {
        let f = try await Fixture.create()
        try f.write("app-only.ignore-test", "app\n")
        try f.write("property-only.ignore-test", "property\n")
        try await f.svn(["propset", "svn:ignore", "property-only.ignore-test", "."])
        let baselineBefore = try await f.client.status(at: f.first)
        let client = SVNClient(executable: f.client.executable, globalIgnores: "app-only.ignore-test")
        let overridden = try await client.status(at: f.first, includeIgnored: true)
        #expect(overridden.first { $0.path == "app-only.ignore-test" }?.item == "ignored")
        #expect(overridden.first { $0.path == "property-only.ignore-test" }?.item == "ignored")

        let empty = SVNClient(executable: f.client.executable, globalIgnores: "")
        let emptyStatus = try await empty.status(at: f.first)
        #expect(emptyStatus.first { $0.path == "app-only.ignore-test" }?.item == "unversioned")
        #expect(!emptyStatus.contains { $0.path == "property-only.ignore-test" })
        let baselineAfter = try await f.client.status(at: f.first)
        #expect(baselineBefore == baselineAfter)
    }

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
        let selectedCommit = try #require(history.first { $0.message == "仅提交中文文件" })
        #expect(selectedCommit.changedPaths.count == 1)
        #expect(selectedCommit.changedPaths.first?.path == "/" + special)
        #expect(selectedCommit.changedPaths.first?.action == "A")
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
        let history = try await f.client.history(at: f.first)
        let propertyCommit = try #require(history.first { $0.message == "仅目录属性" })
        #expect(propertyCommit.changedPaths.count == 1)
        #expect(propertyCommit.changedPaths.first?.path == "/folder")
        #expect(propertyCommit.changedPaths.first?.kind == "dir")
        #expect(propertyCommit.changedPaths.first?.label == "属性修改")
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

    @Test func checkoutPreservesChinesePathsInStreamedAndFinalOutput() async throws {
        let f = try await Fixture.create()
        let filename = "设计文档.txt"
        try f.write(filename, "repository content\n")
        _ = try await f.client.add(paths: [filename], at: f.first)
        _ = try await f.client.commit(paths: [filename], message: "中文文件", at: f.first)

        let destination = f.root.appendingPathComponent("checkout")
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reader = Task {
            var received = ""
            for await text in stream {
                received += text
            }
            return received
        }
        defer { continuation.finish() }
        let output = try await f.client.checkout(
            repository: f.repository.absoluteString,
            destination: destination,
            onOutput: { continuation.yield($0) }
        )
        continuation.finish()
        let received = await reader.value
        #expect(output.contains(filename))
        #expect(received.contains(filename))
        #expect(!output.contains("{U+"))
        #expect(!received.contains("{U+"))
        #expect(try String(contentsOf: destination.appendingPathComponent(filename), encoding: .utf8)
            == "repository content\n")
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
