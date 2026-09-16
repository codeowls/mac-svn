import Foundation

public struct SVNClient: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public static func discoverExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func workingCopy(at directory: URL) async throws -> WorkingCopy {
        let output = try await command(["info", "--xml", "--", ".@"], in: directory)
        return try SVNXML.info(output.stdout)
    }

    public func status(at directory: URL) async throws -> [StatusEntry] {
        let output = try await command(["status", "--xml", "--ignore-externals", "--", ".@"], in: directory)
        return try SVNXML.status(output.stdout)
    }

    public func diff(path: String, at directory: URL) async throws -> String {
        let target = try localTarget(path)
        // --old explicitly parses peg syntax, including newly added names containing @.
        let output = try await command(
            ["diff", "--internal-diff", "--depth", "empty", "--old", target], in: directory
        )
        return output.stdout.isEmpty ? "没有可显示的文本差异。二进制文件或仅目录变更可能没有文本内容。" : output.stdout
    }

    public func history(at directory: URL) async throws -> [LogEntry] {
        // HEAD avoids hiding recent commits when the working-copy root has a mixed revision.
        let output = try await command(["log", "--xml", "--limit", "50", "-r", "HEAD:0", "--", ".@"], in: directory)
        return try SVNXML.log(output.stdout)
    }

    public func update(at directory: URL) async throws -> String {
        let output = try await command(
            ["update", "--accept", "postpone", "--ignore-externals", "--", ".@"], in: directory
        )
        return output.stdout + output.stderr
    }

    public func checkout(repository: String, destination: URL) async throws -> String {
        guard let url = URLComponents(string: repository),
              let scheme = url.scheme,
              ["https", "http", "svn", "svn+ssh", "file"].contains(scheme),
              url.password == nil,
              !repository.contains("\n") else {
            throw SVNError("请输入有效的 SVN 仓库 URL，且不要在 URL 中包含密码。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SVNError("检出目标已存在，请选择一个新的目录名称。")
        }
        let output = try await command([
            "checkout", "--ignore-externals", "--", repository + "@", destination.path
        ])
        return output.stdout + output.stderr
    }

    public func add(paths: [String], at directory: URL) async throws -> String {
        guard !paths.isEmpty else { throw SVNError("请先选择未跟踪文件") }
        // Empty depth prevents a selected directory from silently adding all of its children.
        let targets = try paths.sorted().map(localTarget)
        let output = try await command(["add", "--depth", "empty", "--"] + targets, in: directory)
        return output.stdout + output.stderr
    }

    /// Re-read the working copy before committing; never trust an old UI status snapshot.
    public func commit(paths: [String], message: String, at directory: URL) async throws -> String {
        guard !paths.isEmpty else { throw SVNError("请先勾选要提交的文件") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError("请填写提交说明")
        }
        let targets = try paths.sorted().map(localTarget)
        let current = try await status(at: directory)
        for path in paths {
            guard let entry = current.first(where: { $0.path == path }), entry.canCommit else {
                throw SVNError("\(path) 的状态已变化或不可提交，请刷新后检查。")
            }
            // SVN directory deletions/copies may include descendants even with --depth empty.
            // This MVP rejects these operations instead of committing unselected children.
            if entry.item == "deleted" || entry.item == "replaced" || entry.copied {
                let info = try await command(["info", "--xml", "--", try localTarget(path)], in: directory)
                let root = try XMLReader.parse(info.stdout)
                guard root.child("entry")?.attributes["kind"] == "file" else {
                    throw SVNError("首版暂不支持提交目录删除、替换或带历史的目录复制：\(path)。请用 SVN 命令行处理。")
                }
            }
        }
        do {
            let output = try await command(
                ["commit", "--depth", "empty", "--message", message, "--"] + targets,
                in: directory
            )
            return output.stdout + output.stderr
        } catch {
            throw SVNError("提交未确认完成，请先查看仓库历史核实结果，勿直接重复提交。\n\n\(error.localizedDescription)")
        }
    }

    /// A trailing @ disables peg-revision interpretation for filenames containing @.
    private func localTarget(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), !path.contains("\0") else {
            throw SVNError("文件路径必须位于当前工作副本内")
        }
        return "./" + path + "@"
    }

    private func command(_ arguments: [String], in directory: URL? = nil) async throws -> CommandOutput {
        let output = try await ProcessRunner.run(
            executable: executable,
            arguments: ["--non-interactive"] + arguments,
            directory: directory
        )
        guard output.exitCode == 0 else {
            throw SVNError("SVN 退出码 \(output.exitCode)\n\(output.stderr)\(output.stdout)")
        }
        return output
    }
}
