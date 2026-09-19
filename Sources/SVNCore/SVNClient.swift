import Foundation
import CryptoKit

public struct SVNClient: Sendable {
    public let executable: URL
    private let authentication: SVNAuthentication?
    private let globalIgnores: String?

    public init(
        executable: URL,
        authentication: SVNAuthentication? = nil,
        globalIgnores: String? = nil
    ) {
        self.executable = executable
        self.authentication = authentication
        self.globalIgnores = globalIgnores
    }

    public static func discoverExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 本机执行版本查询，不连接仓库；显式登录要求 SVN 1.14+。
    public func version() async throws -> String {
        let output = try await command(["--version", "--quiet"])
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            throw SVNError(L10n.text("未识别到 SVN 版本，请检查所选文件。\n%@%@", output.stdout, output.stderr))
        }
        guard major > 1 || (major == 1 && minor >= 14) else {
            throw SVNError(L10n.text("当前 SVN 版本为 %@，本应用需要 SVN 1.14 或更新版本。", version))
        }
        return version
    }

    public func workingCopy(at directory: URL) async throws -> WorkingCopy {
        let output = try await command(["info", "--xml", "--", ".@"], in: directory)
        return try SVNXML.info(output.stdout)
    }

    public func status(at directory: URL, includeIgnored: Bool = false) async throws -> [StatusEntry] {
        var arguments = ["status", "--xml", "--ignore-externals"]
        if includeIgnored {
            arguments.append("--no-ignore")
        }
        let output = try await command(arguments + ["--", ".@"], in: directory)
        return try SVNXML.status(output.stdout)
    }

    public func diff(path: String, at directory: URL) async throws -> String {
        let target = try localTarget(path)
        // --old explicitly parses peg syntax, including newly added names containing @.
        let output = try await command(
            ["diff", "--internal-diff", "--depth", "empty", "--old", target], in: directory
        )
        return output.stdout.isEmpty ? L10n.text("没有可显示的文本差异。二进制文件或仅目录变更可能没有文本内容。") : output.stdout
    }

    public func history(at directory: URL) async throws -> [LogEntry] {
        try await historyPage(at: directory).entries
    }

    /// 以末条版本号作为排他游标；多读一条判断是否还有历史，不依赖连续版本号。
    public func historyPage(
        at directory: URL,
        path: String = ".",
        beforeRevision: Int? = nil,
        pageSize: Int = 50
    ) async throws -> HistoryPage {
        guard pageSize > 0, pageSize < Int.max else {
            throw SVNError(L10n.text("历史分页大小必须为正整数。"))
        }
        let target = try localTarget(path)
        if path != "." {
            // 先读本地元数据，防止把当前仓库的会话凭据发送到嵌套或 external 副本。
            let info = try await command(["info", "--xml", "--", target], in: directory)
            let copy = try SVNXML.info(info.stdout)
            guard copy.root.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else {
                throw SVNError(L10n.text("所选路径属于另一个工作副本，请单独打开该副本后查看历史。"))
            }
        }
        let start: String
        if let beforeRevision {
            guard beforeRevision > 0 else {
                throw SVNError(L10n.text("历史分页版本号必须大于 0。"))
            }
            start = String(beforeRevision - 1)
        } else {
            // HEAD 避免混合版本的工作副本隐藏较新的提交；本地目标的 peg 仍由 SVN 定位。
            start = "HEAD"
        }
        let output = try await command(
            ["log", "--xml", "--verbose", "--limit", String(pageSize + 1),
             "-r", "\(start):0", "--", target],
            in: directory
        )
        let logs = try SVNXML.log(output.stdout)
        let entries = Array(logs.prefix(pageSize))
        var nextBeforeRevision: Int?
        if logs.count > pageSize {
            guard let revision = entries.last?.revision, let value = Int(revision), value > 0 else {
                throw SVNError(L10n.text("SVN 历史响应中的分页版本号无效。"))
            }
            nextBeforeRevision = value
        }
        return HistoryPage(entries: entries, nextBeforeRevision: nextBeforeRevision)
    }

    /// 从仓库读取选中提交的差异，不依赖该文件现在是否存在，也不修改工作副本。
    public func historicalDiff(change: LogChangedPath, revision: String, at directory: URL) async throws -> HistoricalDiff {
        guard let revision = Int(revision), revision > 0,
              ["A", "D", "M", "R"].contains(change.action) else {
            throw SVNError(L10n.text("无法识别历史差异的版本号或变更类型。"))
        }
        let relativePath = try historicalRelativePath(change.path)
        let info = try await command(["info", "--xml", "--", ".@"], in: directory)
        let root = try SVNXML.repositoryInfo(info.stdout).rootURL
        let arguments: [String]
        let oldLabel: String
        let newLabel = change.action == "D"
            ? L10n.text("%@ · r%@（已删除）", change.path, revision)
            : "\(change.path) · r\(revision)"
        if change.action == "A", let source = change.copyFromPath {
            let sourcePath = try historicalRelativePath(source)
            guard let sourceRevision = change.copyFromRevision.flatMap(Int.init),
                  sourceRevision >= 0, sourceRevision < revision,
                  let rootURL = URL(string: root) else {
                throw SVNError(L10n.text("复制来源的路径或版本号无效。"))
            }
            oldLabel = L10n.text("%@ · r%@（复制来源）", source, sourceRevision)
            arguments = [
                "diff", "--internal-diff", "--depth", "empty",
                "--old", rootURL.appendingPathComponent(sourcePath).absoluteString + "@\(sourceRevision)",
                "--new", rootURL.appendingPathComponent(relativePath).absoluteString + "@\(revision)"
            ]
        } else {
            oldLabel = "\(change.path) · r\(revision - 1)" + (change.action == "A" ? L10n.text("（不存在）") : "")
            // 用两端都存在的仓库根作为锚点，处理新增/删除路径；替换按删除旧节点并新增显示。
            // 这里的 PATH 是根 URL 下的相对路径，不使用本地目标的尾随 @ 转义。
            arguments = [
                "diff", "--internal-diff", "--depth", "empty", "--notice-ancestry", "--show-copies-as-adds",
                "--old", root + "@\(revision - 1)", "--new", root + "@\(revision)", "--", relativePath
            ]
        }
        let output = try await command(arguments)
        let text = output.stdout + output.stderr
        return HistoricalDiff(
            oldLabel: oldLabel,
            newLabel: newLabel,
            text: text.isEmpty ? L10n.text("这两个版本没有文本或属性差异；纯复制可能与来源完全相同。") : text
        )
    }

    /// 新增无前版本、删除无后版本；带历史新增按复制来源比较，替换仍保留被替换节点。
    public func historicalFileVersions(change: LogChangedPath, revision: String) throws -> HistoricalFileVersions {
        guard let revision = Int(revision), revision > 0,
              ["A", "D", "M", "R"].contains(change.action) else {
            throw SVNError(L10n.text("无法识别历史文件的版本号或变更类型。"))
        }
        _ = try historicalRelativePath(change.path)
        let before: HistoricalFileVersion?
        if change.action == "A", let source = change.copyFromPath {
            _ = try historicalRelativePath(source)
            guard let sourceRevision = change.copyFromRevision.flatMap(Int.init),
                  sourceRevision >= 0, sourceRevision < revision else {
                throw SVNError(L10n.text("复制来源的版本号无效。"))
            }
            before = HistoricalFileVersion(path: source, revision: sourceRevision, isCopySource: true)
        } else {
            before = change.action == "A" ? nil
                : HistoricalFileVersion(path: change.path, revision: revision - 1, isCopySource: false)
        }
        let after = change.action == "D" ? nil
            : HistoricalFileVersion(path: change.path, revision: revision, isCopySource: false)
        return HistoricalFileVersions(before: before, after: after)
    }

    /// 读取仓库原始字节，不经过 UTF-8 转换或关键词展开，Word、图片等二进制文件也保持完整。
    public func historicalFileContent(_ version: HistoricalFileVersion, at directory: URL) async throws -> Data {
        let relativePath = try historicalRelativePath(version.path)
        let info = try await command(["info", "--xml", "--", ".@"], in: directory)
        let root = try SVNXML.repositoryInfo(info.stdout).rootURL
        guard let rootURL = URL(string: root) else {
            throw SVNError(L10n.text("仓库根地址无效。"))
        }
        let target = rootURL.appendingPathComponent(relativePath).absoluteString + "@\(version.revision)"
        let metadata = try await command(["info", "--xml", "-r", String(version.revision), "--", target])
        guard try XMLReader.parse(metadata.stdout).child("entry")?.attributes["kind"] == "file" else {
            throw SVNError(L10n.text("所选版本是目录，不能作为单个文件导出。"))
        }
        let output = try await command(["cat", "--ignore-keywords", "-r", String(version.revision), "--", target])
        try Task.checkCancellation()
        return output.stdoutData
    }

    private func historicalRelativePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw SVNError(L10n.text("历史路径必须是仓库根目录下的绝对路径。"))
        }
        return path == "/" ? "." : String(path.dropFirst())
    }

    /// 仅完成 SVN 未完成的管理任务和清理锁，不使用删除文件或清理外部副本的选项。
    public func cleanup(
        at directory: URL,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let output = try await command(["cleanup", "--", ".@"], in: directory, onOutput: onOutput)
        return output.stdout + output.stderr
    }

    public func update(
        at directory: URL,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let output = try await command(
            ["update", "--accept", "postpone", "--ignore-externals", "--", ".@"],
            in: directory, onOutput: onOutput
        )
        return output.stdout + output.stderr
    }

    /// 按指定深度检出当前仓库目录，默认全递归，外部引用仍由用户单独管理。
    public func checkout(
        repository: String,
        destination: URL,
        depth: CheckoutDepth = .infinity,
        selectedDirectories: [String]? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let target = try Self.repositoryTarget(repository)
        if let selectedDirectories {
            guard !selectedDirectories.isEmpty else {
                throw SVNError(L10n.text("请至少勾选一个目录。"))
            }
            for name in selectedDirectories {
                _ = try Self.childRepositoryURL(parent: repository, name: name)
                _ = try localTarget(name)
            }
            let entries = try await listRepository(repository)
            let directories = Set(entries.filter(\.isDirectory).map(\.name))
            guard Set(selectedDirectories).isSubset(of: directories) else {
                throw SVNError(L10n.text("勾选项已不存在或不是目录，请重新浏览仓库后选择。"))
            }
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SVNError(L10n.text("检出目标不是文件夹，请选择或新建一个空文件夹。"))
            }
            // Finder 的目录显示设置不影响检出，其他隐藏文件仍按非空内容处理。
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
                throw SVNError(L10n.text("检出目标文件夹不为空，请选择或新建一个空文件夹；已有工作副本请直接打开。"))
            }
        }
        var result = ""
        var transferError: SVNError
        do {
            let output = try await command([
                "checkout", "--depth", selectedDirectories == nil ? depth.rawValue : "empty",
                "--ignore-externals", "--", target, destination.path
            ], onOutput: onOutput)
            result += output.stdout + output.stderr
            result += try await expandCheckoutDirectories(selectedDirectories, at: destination, onOutput: onOutput)
            return result
        } catch let error as SVNError where error.isInterruptedTransfer {
            transferError = error
        }

        // 仅恢复本次从空目录开始的检出；子进程已退出，最多自动清理、续传两次。
        for attempt in 1...2 {
            try Task.checkCancellation()
            let notice = L10n.text("\n检出传输中断，正在自动恢复（%@/2）：清理工作副本锁后继续更新。\n", attempt)
            result += transferError.diagnostic + notice
            onOutput?(notice)
            try await Task.sleep(for: .seconds(1))
            guard fileManager.fileExists(atPath: destination.appendingPathComponent(".svn").path) else {
                throw transferError
            }
            let copy = try await workingCopy(at: destination)
            let expectedURL = URL(string: repository)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let actualURL = URL(string: copy.repositoryURL)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard copy.root.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path,
                  actualURL == expectedURL else {
                throw SVNError(L10n.text("自动恢复已停止：目标工作副本与本次检出目录或仓库不一致。\n%@", transferError.message))
            }
            // 清理失败必须停止，不能继续更新，更不能删除目录后重新检出。
            result += try await cleanup(at: destination, onOutput: onOutput)
            try Task.checkCancellation()
            do {
                // 选目录模式只更新根本身；不能对已有子目录使用 --set-depth empty，
                // 否则 SVN 会收缩副本并移除已下载目录。随后补齐全部已选目录。
                let depthOptions = selectedDirectories == nil
                    ? ["--set-depth", depth.rawValue] : ["--depth", "empty"]
                let update = try await command(
                    ["update"] + depthOptions
                        + ["--accept", "postpone", "--ignore-externals", "--", ".@"],
                    in: destination, onOutput: onOutput
                )
                result += update.stdout + update.stderr
                result += try await expandCheckoutDirectories(selectedDirectories, at: destination, onOutput: onOutput)
                let completed = L10n.text("\n自动恢复完成。\n")
                onOutput?(completed)
                return result + completed
            } catch let error as SVNError where error.isInterruptedTransfer {
                transferError = error
            }
        }
        throw SVNError(L10n.text("自动恢复已尝试 2 次，检出仍未完成；已下载文件保留，请检查网络或服务器后继续更新。\n\n%@", transferError.message))
    }

    /// 初次检出和恢复使用同一组选中目录，包含中断时尚未开始下载的目录。
    private func expandCheckoutDirectories(
        _ directories: [String]?,
        at destination: URL,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let directories else { return "" }
        try Task.checkCancellation()
        let targets = try Set(directories).sorted().map(localTarget)
        let output = try await command(
            ["update", "--set-depth", "infinity", "--accept", "postpone", "--ignore-externals", "--"] + targets,
            in: destination, onOutput: onOutput
        )
        return output.stdout + output.stderr
    }

    /// 失败或取消后只检查目标本身；不自动清理、不递归删除，也不误打开其祖先工作副本。
    public func inspectCheckout(at directory: URL) async throws -> CheckoutInspection {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return CheckoutInspection(
                directory: directory, workingCopy: nil, summary: L10n.text("目标目录尚未创建。"),
                guidance: L10n.text("可修正原始错误后重新检出。")
            )
        }
        guard isDirectory.boolValue else {
            throw SVNError(L10n.text("检出目标不是文件夹：%@", directory.path))
        }
        let contents = try manager.contentsOfDirectory(atPath: directory.path)
        guard contents.contains(".svn") else {
            let empty = contents.allSatisfy { $0 == ".DS_Store" }
            return CheckoutInspection(
                directory: directory, workingCopy: nil,
                summary: empty ? L10n.text("目标文件夹为空，未发现 SVN 元数据。") : L10n.text("目标文件夹有内容，但未发现 SVN 元数据。"),
                guidance: empty ? L10n.text("可修正原始错误后重新检出。")
                    : L10n.text("请在访达中核对并保留所需文件，重新检出时选择其他空目录。")
            )
        }
        let copy = try await workingCopy(at: directory)
        // 目标 URL 可能创建于目录出现之前，比较规范路径，避免目录尾随斜线造成误判。
        guard copy.root.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else {
            throw SVNError(L10n.text("目标未识别为独立工作副本，请在访达中检查：%@", directory.path))
        }
        // verbose 包含正常但带工作副本锁的节点；仅检查本地，不能据此断言已完整下载。
        let output = try await command(["status", "--xml", "--verbose", "--ignore-externals", "--", ".@"], in: directory)
        let nodes = try XMLReader.parse(output.stdout).descendants("wc-status")
        let locked = nodes.contains { $0.attributes["wc-locked"] == "true" }
        let entries = try SVNXML.status(output.stdout)
        let incomplete = entries.filter { ["incomplete", "missing", "obstructed"].contains($0.item) }.count
        let conflicts = entries.filter(\.isConflict).count
        return CheckoutInspection(
            directory: directory, workingCopy: copy,
            summary: L10n.text("已识别工作副本；不完整／缺失／阻塞 %@ 项，冲突 %@ 项。", incomplete, conflicts)
                + (locked ? L10n.text(" 检测到工作副本锁。") : ""),
            guidance: (locked ? L10n.text("确认其他 SVN 操作已结束后，右键左侧副本选择“清理工作副本锁…”，再重新检查。") : "")
                + L10n.text("可打开副本检查状态，再手动更新补齐；本地检查不能证明检出完整。不要直接在此非空目录重新检出。")
        )
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
            throw SVNError(L10n.text("无效的仓库目录名称"))
        }
        guard let url = URL(string: parent) else {
            throw SVNError(L10n.text("无效的仓库 URL"))
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
            throw SVNError(L10n.text("请输入完整的 SVN 仓库或分支 URL，且不要在 URL 中包含密码、查询参数或片段。"))
        }
        return repository + "@"
    }

    public func add(paths: [String], at directory: URL) async throws -> String {
        guard !paths.isEmpty else { throw SVNError(L10n.text("请先选择未跟踪文件")) }
        // Empty depth prevents a selected directory from silently adding all of its children.
        let targets = try paths.sorted().map(localTarget)
        let output = try await command(["add", "--depth", "empty", "--"] + targets, in: directory)
        return output.stdout + output.stderr
    }

    /// 只读取当前目录的 svn:ignore，不合并全局或祖先规则；保留属性不存在与空值的区别。
    public func directoryIgnores(path: String = ".", at directory: URL) async throws -> DirectoryIgnoreSettings {
        let target = try localTarget(path)
        let output = try await command(["info", "--xml", "--", target], in: directory)
        let copy = try SVNXML.info(output.stdout)
        let info = try XMLReader.parse(output.stdout).child("entry")
        guard copy.root.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
              info?.attributes["kind"] == "dir",
              let schedule = info?.child("wc-info")?.child("schedule")?.text,
              ["normal", "add"].contains(schedule) else {
            throw SVNError(L10n.text("请选择当前工作副本中有效的受控目录；不能修改外部副本或待删除、替换目录的忽略规则。"))
        }
        let current = try await status(at: directory, includeIgnored: true)
        if let entry = current.first(where: { $0.path == path }),
           entry.isConflict || ["missing", "obstructed", "incomplete", "external"].contains(entry.item) {
            throw SVNError(L10n.text("目录状态不允许编辑忽略规则：%@。请先处理冲突或异常状态。", path))
        }
        let properties = try await command(["proplist", "--xml", "--verbose", "--depth", "empty", "--", target], in: directory)
        let xml = try XMLReader.parse(properties.stdout)
        guard xml.name == "properties" else { throw SVNError(L10n.text("SVN 属性响应格式不正确。")) }
        let property = xml.descendants("property").first { $0.attributes["name"] == "svn:ignore" }
        var patterns = property?.text
        if let encoding = property?.attributes["encoding"] {
            guard encoding == "base64", let data = Data(base64Encoded: property?.text ?? ""),
                  let text = String(data: data, encoding: .utf8) else {
                throw SVNError(L10n.text("目录忽略属性不是有效的 UTF-8 文本，无法编辑。"))
            }
            patterns = text
        }
        return DirectoryIgnoreSettings(root: directory, path: path, patterns: patterns)
    }

    /// 保存前核对原属性，避免覆盖其他客户端在编辑期间修改的规则；只写入一个目录属性。
    public func saveDirectoryIgnores(_ settings: DirectoryIgnoreSettings, patterns: String) async throws -> String {
        let normalized = try SVNConfiguration.normalizeDirectoryIgnores(patterns)
        let expected: String? = normalized.isEmpty ? nil : normalized
        let current = try await directoryIgnores(path: settings.path, at: settings.root)
        guard current.patterns == settings.patterns else {
            throw SVNError(L10n.text("编辑期间目录忽略规则已变化，尚未保存。请关闭后重新读取规则。"))
        }
        guard current.patterns != expected else { return L10n.text("目录忽略规则没有变化。") }
        try Task.checkCancellation()
        let target = try localTarget(settings.path)
        let arguments = expected.map {
            ["propset", "--depth", "empty", "--", "svn:ignore", $0, target]
        } ?? ["propdel", "--depth", "empty", "--", "svn:ignore", target]
        let output = try await command(arguments, in: settings.root)
        let saved = try await directoryIgnores(path: settings.path, at: settings.root)
        guard saved.patterns == expected else {
            throw SVNError(L10n.text("保存命令已执行，但读回的目录忽略规则与预期不一致，请刷新后检查。"))
        }
        return L10n.text("目录忽略规则已保存为本地属性变更；提交该目录后才会共享到仓库。\n") + output.stdout + output.stderr
    }

    /// 从 SVN 冲突元数据读取真实的基准、本地及传入版本路径；查看不会自动解决冲突。
    public func conflictDetails(path: String, at directory: URL) async throws -> ConflictDetails {
        let target = try localTarget(path)
        let current = try await status(at: directory)
        guard let entry = current.first(where: { $0.path == path }), entry.isConflict else {
            throw SVNError(L10n.text("该路径已不处于冲突状态，请刷新后检查。"))
        }
        let output = try await command(["info", "--xml", "--depth", "empty", "--", target], in: directory)
        let copy = try SVNXML.info(output.stdout)
        guard copy.root.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
              let info = try XMLReader.parse(output.stdout).child("entry") else {
            throw SVNError(L10n.text("冲突路径不属于当前工作副本。"))
        }
        let nodes = info.children.filter { ["conflict", "tree-conflict"].contains($0.name) }
        guard !nodes.isEmpty else { throw SVNError(L10n.text("SVN 未返回冲突详情，请刷新后重新读取。")) }
        var summary: [String] = []
        var files: [ConflictFile] = []
        if info.attributes["kind"] == "file", FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            files.append(ConflictFile(id: "working", title: L10n.text("当前工作文件"), url: directory.appendingPathComponent(path)))
        }
        for node in nodes {
            let type = node.name == "tree-conflict" ? "tree" : node.attributes["type"] ?? "unknown"
            let typeLabel = ["text": L10n.text("文件内容冲突"), "property": L10n.text("属性冲突"), "tree": L10n.text("树冲突")][type] ?? L10n.text("未知冲突")
            let operation = node.attributes["operation"] ?? L10n.text("未知")
            let operationLabel = ["update": L10n.text("更新"), "switch": L10n.text("切换"), "merge": L10n.text("合并")][operation] ?? operation
            summary.append(typeLabel + L10n.text(" · 操作：") + operationLabel)
            if type == "tree" {
                let reason = node.attributes["reason"] ?? L10n.text("未知")
                let action = node.attributes["action"] ?? L10n.text("未知")
                let reasonLabel = [
                    "edit": L10n.text("本地修改"), "delete": L10n.text("本地删除"), "missing": L10n.text("本地缺失"), "obstructed": L10n.text("路径被占用"),
                    "added": L10n.text("本地新增"), "replaced": L10n.text("本地替换"), "unversioned": L10n.text("未受控项目"),
                    "moved-away": L10n.text("已移走"), "moved-here": L10n.text("已移入")
                ][reason] ?? reason
                let actionLabel = ["edit": L10n.text("修改"), "delete": L10n.text("删除"), "add": L10n.text("新增"), "replace": L10n.text("替换")][action] ?? action
                summary.append(L10n.text("本地原因：%@ · 传入操作：%@", reasonLabel, actionLabel))
            }
            for version in node.children where version.name == "version" {
                let label = version.attributes["side"] == "source-left" ? L10n.text("原基准版本") : L10n.text("传入版本")
                let kind = version.attributes["kind"] ?? L10n.text("未知类型")
                let kindLabel = ["file": L10n.text("文件"), "dir": L10n.text("目录"), "none": L10n.text("节点不存在")][kind] ?? kind
                summary.append("\(label)：/\(version.attributes["path-in-repos"] ?? "") · r\(version.attributes["revision"] ?? "?") · \(kindLabel)")
            }
            for (key, title) in [
                ("prev-base-file", L10n.text("原基准内容")), ("prev-wc-file", L10n.text("合并前本地内容")),
                ("cur-base-file", L10n.text("传入内容")), ("prop-file", L10n.text("属性冲突说明"))
            ] {
                if let file = node.child(key), !file.text.isEmpty {
                    files.append(ConflictFile(id: key, title: title, url: URL(fileURLWithPath: file.text)))
                }
            }
        }
        let digest = try nodes.map(conflictMetadataDigest).sorted().joined(separator: "\n")
        let canResolve = entry.item == "conflicted" && entry.properties != "conflicted" && !entry.treeConflict
            && info.attributes["kind"] == "file" && nodes.allSatisfy { $0.attributes["type"] == "text" }
        return ConflictDetails(
            root: directory, entry: entry, summary: summary, files: files,
            canMarkResolved: canResolve, metadataDigest: digest
        )
    }

    /// 元数据属性的输出顺序可能变化，按键和子节点排序后生成可重读比较的指纹。
    func conflictMetadataDigest(_ node: XMLNode) throws -> String {
        let value: [String: Any] = [
            "name": node.name, "text": node.children.isEmpty ? node.text : "",
            "attributes": node.attributes, "children": try node.children.map(conflictMetadataDigest).sorted()
        ]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).description
    }

    public func conflictFileContent(_ file: ConflictFile, at directory: URL) throws -> Data {
        let root = directory.resolvingSymlinksInPath().path
        let path = file.url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/"),
              try FileManager.default.attributesOfItem(atPath: file.url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw SVNError(L10n.text("冲突查看仅支持当前工作副本内的普通文件，不跟随符号链接。"))
        }
        return try Data(contentsOf: file.url)
    }

    /// 在确认前读取最终工作内容；只支持单文件内容冲突，不连带接受属性或树冲突。
    public func prepareConflictResolution(_ details: ConflictDetails) async throws -> ConflictResolutionPlan {
        let current = try await conflictDetails(path: details.entry.path, at: details.root)
        guard current.canMarkResolved, current.entry == details.entry,
              current.metadataDigest == details.metadataDigest,
              let working = current.files.first(where: { $0.id == "working" }) else {
            throw SVNError(L10n.text("冲突状态已变化，或包含尚不支持直接标记的属性／树冲突。请重新读取详情。"))
        }
        let data = try conflictFileContent(working, at: details.root)
        let text = String(data: data, encoding: .utf8)
        let markers = text?.components(separatedBy: .newlines).contains {
            $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("||||||| ") || $0.hasPrefix(">>>>>>> ")
        } ?? false
        return ConflictResolutionPlan(
            details: details,
            preview: text ?? L10n.text("当前内容不是 UTF-8 文本（%@ 字节）。请用合适的编辑器检查最终文件后再确认。", data.count),
            containsConflictMarkers: markers, contentDigest: SHA256.hash(data: data).description
        )
    }

    /// 确认内容与冲突身份未变化后才采用 working；命令结束后以 SVN 重新读取的状态为准。
    public func resolveConflict(_ plan: ConflictResolutionPlan) async throws -> String {
        let fresh = try await prepareConflictResolution(plan.details)
        guard fresh.contentDigest == plan.contentDigest else {
            throw SVNError(L10n.text("确认期间工作文件内容已变化，尚未标记解决。请重新检查最终内容。"))
        }
        try Task.checkCancellation()
        let output = try await command(
            ["resolve", "--accept", "working", "--depth", "empty", "--", try localTarget(plan.details.entry.path)],
            in: plan.details.root
        )
        let entries = try await status(at: plan.details.root)
        guard !entries.contains(where: { $0.path == plan.details.entry.path && $0.isConflict }) else {
            throw SVNError(L10n.text("标记命令已执行，但该文件仍处于冲突状态，请重新检查。\n%@%@", output.stdout, output.stderr))
        }
        return L10n.text("已保留当前工作文件并标记解决；尚未提交到仓库。\n") + output.stdout + output.stderr
    }

    /// Re-read the working copy before committing; never trust an old UI status snapshot.
    public func commit(
        paths: [String], message: String, at directory: URL,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let plan = try await prepareCommit(paths: paths, message: message, at: directory)
        guard Set(plan.items.map { $0.path }) == Set(paths) else {
            throw SVNError(L10n.text("此提交涉及关联路径，请先检查并确认完整提交清单。"))
        }
        return try await commit(plan, onOutput: onOutput)
    }

    /// 只生成待确认清单，不修改文件；目录按 empty 深度处理，结构性目录还原另行支持。
    public func prepareRevert(paths: [String], at directory: URL) async throws -> RevertPlan {
        guard !paths.isEmpty else { throw SVNError(L10n.text("请先选择需要还原的项目。")) }
        let paths = Set(paths)
        let current = try await status(at: directory)
        var items: [RevertItem] = []
        for path in paths.sorted() {
            let target = try localTarget(path)
            guard let entry = current.first(where: { $0.path == path }), entry.canRevert else {
                throw SVNError(L10n.text("%@ 当前不能还原，请刷新状态；冲突需通过冲突处理流程解决。", path))
            }
            let output = try await command(["info", "--xml", "--", target], in: directory)
            let copy = try SVNXML.info(output.stdout)
            guard copy.root.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else {
                throw SVNError(L10n.text("不能跨工作副本还原：%@。", path))
            }
            let info = try XMLReader.parse(output.stdout).child("entry")
            let isDirectory = info?.attributes["kind"] == "dir"
            if isDirectory, entry.copied || ["deleted", "replaced", "missing"].contains(entry.item) {
                throw SVNError(L10n.text("目录删除、替换、缺失或带历史复制可能影响未选子项，当前不支持直接还原：%@。", path))
            }
            if isDirectory, entry.item == "added" {
                let children = current.filter {
                    $0.path.hasPrefix(path + "/") && !["unversioned", "ignored", "external"].contains($0.item)
                }
                guard children.allSatisfy({ paths.contains($0.path) }) else {
                    throw SVNError(L10n.text("还原新增目录前，请一并选择已纳入版本控制的子项：%@。", path))
                }
            }
            // SVN move 的两端存在元数据关联，不能把其中一端当作独立复制或删除还原。
            let wcInfo = info?.child("wc-info")
            guard wcInfo?.child("moved-from") == nil, wcInfo?.child("moved-to") == nil else {
                throw SVNError(L10n.text("移动操作涉及源路径和目标路径，当前不支持单独还原：%@。", path))
            }
            // 已安排删除的路径没有可读取的 WORKING 属性，确认清单使用将恢复的 BASE 属性。
            let propertyRevision = entry.item == "deleted" ? ["--revision", "BASE"] : []
            let properties = try await command(
                ["proplist", "--xml", "--verbose", "--depth", "empty"] + propertyRevision + ["--", target],
                in: directory
            )
            let preview = try await diff(path: path, at: directory)
            let effect: String
            switch entry.item {
            case "added":
                effect = entry.copied ? L10n.text("撤销复制安排，并删除复制产生的本地文件及其未提交修改。") : L10n.text("撤销新增安排，保留本地文件或目录；属性修改将丢弃。")
            case "deleted", "missing":
                effect = L10n.text("恢复工作副本 BASE 版本的文件及属性，取消删除安排；现有本地内容将被覆盖。")
            case "replaced":
                effect = L10n.text("丢弃替换后的内容与属性，恢复原文件的 BASE 版本。")
            default:
                effect = isDirectory ? L10n.text("丢弃当前目录的属性修改，不还原未选子项。") : L10n.text("丢弃未提交的内容与属性修改，恢复工作副本 BASE 版本。")
            }
            items.append(RevertItem(
                entry: entry, isDirectory: isDirectory, effect: effect, preview: preview,
                baseRevision: copy.revision, properties: properties.stdout,
                contentDigest: try contentDigest(at: directory.appendingPathComponent(path), isDirectory: isDirectory)
            ))
        }
        return RevertPlan(root: directory, items: items)
    }

    /// 确认后重新核对状态、属性和内容；先还原子项，避免新增父目录隐式影响子项。
    public func revert(_ plan: RevertPlan) async throws -> String {
        let fresh = try await prepareRevert(paths: plan.items.map { $0.entry.path }, at: plan.root)
        guard fresh.items == plan.items else {
            throw SVNError(L10n.text("确认期间文件或状态发生变化，尚未执行还原。请重新检查还原清单。"))
        }
        try Task.checkCancellation()
        let paths = plan.items.map { $0.entry.path }.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0 < $1 : leftDepth > rightDepth
        }
        let output = try await command(["revert", "--depth", "empty", "--"] + paths.map(localTarget), in: plan.root)
        let remaining = try await status(at: plan.root)
        guard !remaining.contains(where: { paths.contains($0.path) && !["unversioned", "ignored"].contains($0.item) }) else {
            throw SVNError(L10n.text("还原命令已执行，但部分目标仍有未提交修改，请检查状态。\n%@%@", output.stdout, output.stderr))
        }
        return output.stdout + output.stderr
    }

    /// 二进制内容也参与确认快照；读取符号链接本身，不跟随链接读取其他位置的文件。
    func contentDigest(at url: URL, isDirectory: Bool) throws -> String? {
        if isDirectory { return nil }
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return nil
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return SHA256.hash(data: Data(try manager.destinationOfSymbolicLink(atPath: url.path).utf8)).description
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SVNError(L10n.text("目标不是普通文件或符号链接：%@。", url.lastPathComponent))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().description
    }

    /// A trailing @ disables peg-revision interpretation for filenames containing @.
    func localTarget(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), !path.contains("\0") else {
            throw SVNError(L10n.text("文件路径必须位于当前工作副本内"))
        }
        return "./" + path + "@"
    }

    func command(
        _ arguments: [String],
        in directory: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandOutput {
        var options = ["--non-interactive"]
        if let globalIgnores {
            let patterns = try SVNConfiguration.normalizeIgnorePatterns(globalIgnores)
            options += ["--config-option", "config:miscellany:global-ignores=\(patterns)"]
        }
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
