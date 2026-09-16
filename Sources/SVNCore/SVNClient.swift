import Foundation

public struct SVNClient: Sendable {
    public let executable: URL
    private let authentication: SVNAuthentication?

    public init(executable: URL, authentication: SVNAuthentication? = nil) {
        self.executable = executable
        self.authentication = authentication
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
        let output = try await command(
            ["log", "--xml", "--verbose", "--limit", "50", "-r", "HEAD:0", "--", ".@"], in: directory
        )
        return try SVNXML.log(output.stdout)
    }

    public func update(at directory: URL) async throws -> String {
        let output = try await command(
            ["update", "--accept", "postpone", "--ignore-externals", "--", ".@"], in: directory
        )
        return output.stdout + output.stderr
    }

    /// 递归检出当前仓库目录的全部内容，外部引用仍由用户单独管理。
    public func checkout(
        repository: String,
        destination: URL,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let target = try Self.repositoryTarget(repository)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SVNError("检出目标不是文件夹，请选择或新建一个空文件夹。")
            }
            // Finder 的目录显示设置不影响检出，其他隐藏文件仍按非空内容处理。
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
                throw SVNError("检出目标文件夹不为空，请选择或新建一个空文件夹；已有工作副本请直接打开。")
            }
        }
        let output = try await command([
            "checkout", "--depth", "infinity", "--ignore-externals", "--", target, destination.path
        ], onOutput: onOutput)
        return output.stdout + output.stderr
    }

    /// Query repository metadata without requiring a local working copy.
    public func repositoryLocation(_ repository: String) async throws -> RepositoryLocation {
        let target = try Self.repositoryTarget(repository)
        let output = try await command(["info", "--xml", "--revision", "HEAD", "--", target])
        return try SVNXML.repositoryInfo(output.stdout)
    }

    /// Read one remote directory at a time, including nonstandard branch layouts.
    public func listRepository(_ repository: String) async throws -> [RepositoryEntry] {
        let target = try Self.repositoryTarget(repository)
        let output = try await command(["list", "--xml", "--revision", "HEAD", "--", target])
        return try SVNXML.repositoryEntries(output.stdout)
    }

    public static func childRepositoryURL(parent: String, name: String) throws -> String {
        _ = try repositoryTarget(parent)
        guard !name.isEmpty, ![".", ".."].contains(name), !name.contains("/") else {
            throw SVNError("无效的仓库目录名称")
        }
        guard let url = URL(string: parent) else {
            throw SVNError("无效的仓库 URL")
        }
        return url.appendingPathComponent(name).absoluteString
    }

    private static func repositoryTarget(_ repository: String) throws -> String {
        guard let url = URLComponents(string: repository),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "svn", "svn+ssh", "file"].contains(scheme),
              scheme == "file" || !(url.host ?? "").isEmpty,
              url.password == nil, url.query == nil, url.fragment == nil,
              !repository.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SVNError("请输入完整的 SVN 仓库或分支 URL，且不要在 URL 中包含密码、查询参数或片段。")
        }
        return repository + "@"
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

    private func command(
        _ arguments: [String],
        in directory: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandOutput {
        var options = ["--non-interactive"]
        var input: Data?
        if let authentication {
            options += ["--no-auth-cache", "--username", authentication.username, "--password-from-stdin"]
            input = Data((authentication.password + "\n").utf8)
        }
        let output = try await ProcessRunner.run(
            executable: executable,
            arguments: options + arguments,
            directory: directory,
            standardInput: input,
            onOutput: onOutput
        )
        guard output.exitCode == 0 else {
            throw SVNError(output: output, xmlOutput: arguments.contains("--xml"))
        }
        return output
    }
}
