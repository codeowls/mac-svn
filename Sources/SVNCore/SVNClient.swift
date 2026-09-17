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
            throw SVNError("未识别到 SVN 版本，请检查所选文件。\n\(output.stdout)\(output.stderr)")
        }
        guard major > 1 || (major == 1 && minor >= 14) else {
            throw SVNError("当前 SVN 版本为 \(version)，本应用需要 SVN 1.14 或更新版本。")
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
        return output.stdout.isEmpty ? "没有可显示的文本差异。二进制文件或仅目录变更可能没有文本内容。" : output.stdout
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
            throw SVNError("历史分页大小必须为正整数。")
        }
        let target = try localTarget(path)
        if path != "." {
            // 先读本地元数据，防止把当前仓库的会话凭据发送到嵌套或 external 副本。
            let info = try await command(["info", "--xml", "--", target], in: directory)
            let copy = try SVNXML.info(info.stdout)
            guard copy.root.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else {
                throw SVNError("所选路径属于另一个工作副本，请单独打开该副本后查看历史。")
            }
        }
        let start: String
        if let beforeRevision {
            guard beforeRevision > 0 else {
                throw SVNError("历史分页版本号必须大于 0。")
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
                throw SVNError("SVN 历史响应中的分页版本号无效。")
            }
            nextBeforeRevision = value
        }
        return HistoryPage(entries: entries, nextBeforeRevision: nextBeforeRevision)
    }

    /// 从仓库读取选中提交的差异，不依赖该文件现在是否存在，也不修改工作副本。
    public func historicalDiff(change: LogChangedPath, revision: String, at directory: URL) async throws -> HistoricalDiff {
        guard let revision = Int(revision), revision > 0,
              ["A", "D", "M", "R"].contains(change.action) else {
            throw SVNError("无法识别历史差异的版本号或变更类型。")
        }
        let relativePath = try historicalRelativePath(change.path)
        let info = try await command(["info", "--xml", "--", ".@"], in: directory)
        let root = try SVNXML.repositoryInfo(info.stdout).rootURL
        let arguments: [String]
        let oldLabel: String
        let newLabel = change.action == "D"
            ? "\(change.path) · r\(revision)（已删除）"
            : "\(change.path) · r\(revision)"
        if change.action == "A", let source = change.copyFromPath {
            let sourcePath = try historicalRelativePath(source)
            guard let sourceRevision = change.copyFromRevision.flatMap(Int.init),
                  sourceRevision >= 0, sourceRevision < revision,
                  let rootURL = URL(string: root) else {
                throw SVNError("复制来源的路径或版本号无效。")
            }
            oldLabel = "\(source) · r\(sourceRevision)（复制来源）"
            arguments = [
                "diff", "--internal-diff", "--depth", "empty",
                "--old", rootURL.appendingPathComponent(sourcePath).absoluteString + "@\(sourceRevision)",
                "--new", rootURL.appendingPathComponent(relativePath).absoluteString + "@\(revision)"
            ]
        } else {
            oldLabel = "\(change.path) · r\(revision - 1)" + (change.action == "A" ? "（不存在）" : "")
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
            text: text.isEmpty ? "这两个版本没有文本或属性差异；纯复制可能与来源完全相同。" : text
        )
    }

    /// 新增无前版本、删除无后版本；带历史新增按复制来源比较，替换仍保留被替换节点。
    public func historicalFileVersions(change: LogChangedPath, revision: String) throws -> HistoricalFileVersions {
        guard let revision = Int(revision), revision > 0,
              ["A", "D", "M", "R"].contains(change.action) else {
            throw SVNError("无法识别历史文件的版本号或变更类型。")
        }
        _ = try historicalRelativePath(change.path)
        let before: HistoricalFileVersion?
        if change.action == "A", let source = change.copyFromPath {
            _ = try historicalRelativePath(source)
            guard let sourceRevision = change.copyFromRevision.flatMap(Int.init),
                  sourceRevision >= 0, sourceRevision < revision else {
                throw SVNError("复制来源的版本号无效。")
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
            throw SVNError("仓库根地址无效。")
        }
        let target = rootURL.appendingPathComponent(relativePath).absoluteString + "@\(version.revision)"
        let metadata = try await command(["info", "--xml", "-r", String(version.revision), "--", target])
        guard try XMLReader.parse(metadata.stdout).child("entry")?.attributes["kind"] == "file" else {
            throw SVNError("所选版本是目录，不能作为单个文件导出。")
        }
        let output = try await command(["cat", "--ignore-keywords", "-r", String(version.revision), "--", target])
        try Task.checkCancellation()
        return output.stdoutData
    }

    private func historicalRelativePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw SVNError("历史路径必须是仓库根目录下的绝对路径。")
        }
        return path == "/" ? "." : String(path.dropFirst())
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

    /// 失败或取消后只检查目标本身；不自动清理、不递归删除，也不误打开其祖先工作副本。
    public func inspectCheckout(at directory: URL) async throws -> CheckoutInspection {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return CheckoutInspection(
                directory: directory, workingCopy: nil, summary: "目标目录尚未创建。",
                guidance: "可修正原始错误后重新检出。"
            )
        }
        guard isDirectory.boolValue else {
            throw SVNError("检出目标不是文件夹：\(directory.path)")
        }
        let contents = try manager.contentsOfDirectory(atPath: directory.path)
        guard contents.contains(".svn") else {
            let empty = contents.allSatisfy { $0 == ".DS_Store" }
            return CheckoutInspection(
                directory: directory, workingCopy: nil,
                summary: empty ? "目标文件夹为空，未发现 SVN 元数据。" : "目标文件夹有内容，但未发现 SVN 元数据。",
                guidance: empty ? "可修正原始错误后重新检出。"
                    : "请在访达中核对并保留所需文件，重新检出时选择其他空目录。"
            )
        }
        let copy = try await workingCopy(at: directory)
        // 目标 URL 可能创建于目录出现之前，比较规范路径，避免目录尾随斜线造成误判。
        guard copy.root.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else {
            throw SVNError("目标未识别为独立工作副本，请在访达中检查：\(directory.path)")
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
            summary: "已识别工作副本；不完整／缺失／阻塞 \(incomplete) 项，冲突 \(conflicts) 项。"
                + (locked ? " 检测到工作副本锁。" : ""),
            guidance: (locked ? "确认其他 SVN 操作已结束后，使用 SVN cleanup 清理工作副本锁，再重新检查。" : "")
                + "可打开副本检查状态，再手动更新补齐；本地检查不能证明检出完整。不要直接在此非空目录重新检出。"
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
            throw SVNError("请选择当前工作副本中有效的受控目录；不能修改外部副本或待删除、替换目录的忽略规则。")
        }
        let current = try await status(at: directory, includeIgnored: true)
        if let entry = current.first(where: { $0.path == path }),
           entry.isConflict || ["missing", "obstructed", "incomplete", "external"].contains(entry.item) {
            throw SVNError("目录状态不允许编辑忽略规则：\(path)。请先处理冲突或异常状态。")
        }
        let properties = try await command(["proplist", "--xml", "--verbose", "--depth", "empty", "--", target], in: directory)
        let xml = try XMLReader.parse(properties.stdout)
        guard xml.name == "properties" else { throw SVNError("SVN 属性响应格式不正确。") }
        let property = xml.descendants("property").first { $0.attributes["name"] == "svn:ignore" }
        var patterns = property?.text
        if let encoding = property?.attributes["encoding"] {
            guard encoding == "base64", let data = Data(base64Encoded: property?.text ?? ""),
                  let text = String(data: data, encoding: .utf8) else {
                throw SVNError("目录忽略属性不是有效的 UTF-8 文本，无法编辑。")
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
            throw SVNError("编辑期间目录忽略规则已变化，尚未保存。请关闭后重新读取规则。")
        }
        guard current.patterns != expected else { return "目录忽略规则没有变化。" }
        try Task.checkCancellation()
        let target = try localTarget(settings.path)
        let arguments = expected.map {
            ["propset", "--depth", "empty", "--", "svn:ignore", $0, target]
        } ?? ["propdel", "--depth", "empty", "--", "svn:ignore", target]
        let output = try await command(arguments, in: settings.root)
        let saved = try await directoryIgnores(path: settings.path, at: settings.root)
        guard saved.patterns == expected else {
            throw SVNError("保存命令已执行，但读回的目录忽略规则与预期不一致，请刷新后检查。")
        }
        return "目录忽略规则已保存为本地属性变更；提交该目录后才会共享到仓库。\n" + output.stdout + output.stderr
    }

    /// 从 SVN 冲突元数据读取真实的基准、本地及传入版本路径；查看不会自动解决冲突。
    public func conflictDetails(path: String, at directory: URL) async throws -> ConflictDetails {
        let target = try localTarget(path)
        let current = try await status(at: directory)
        guard let entry = current.first(where: { $0.path == path }), entry.isConflict else {
            throw SVNError("该路径已不处于冲突状态，请刷新后检查。")
        }
        let output = try await command(["info", "--xml", "--depth", "empty", "--", target], in: directory)
        let copy = try SVNXML.info(output.stdout)
        guard copy.root.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
              let info = try XMLReader.parse(output.stdout).child("entry") else {
            throw SVNError("冲突路径不属于当前工作副本。")
        }
        let nodes = info.children.filter { ["conflict", "tree-conflict"].contains($0.name) }
        guard !nodes.isEmpty else { throw SVNError("SVN 未返回冲突详情，请刷新后重新读取。") }
        var summary: [String] = []
        var files: [ConflictFile] = []
        if info.attributes["kind"] == "file", FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            files.append(ConflictFile(id: "working", title: "当前工作文件", url: directory.appendingPathComponent(path)))
        }
        for node in nodes {
            let type = node.name == "tree-conflict" ? "tree" : node.attributes["type"] ?? "unknown"
            let typeLabel = ["text": "文件内容冲突", "property": "属性冲突", "tree": "树冲突"][type] ?? "未知冲突"
            let operation = node.attributes["operation"] ?? "未知"
            let operationLabel = ["update": "更新", "switch": "切换", "merge": "合并"][operation] ?? operation
            summary.append(typeLabel + " · 操作：" + operationLabel)
            if type == "tree" {
                let reason = node.attributes["reason"] ?? "未知"
                let action = node.attributes["action"] ?? "未知"
                let reasonLabel = [
                    "edit": "本地修改", "delete": "本地删除", "missing": "本地缺失", "obstructed": "路径被占用",
                    "added": "本地新增", "replaced": "本地替换", "unversioned": "未受控项目",
                    "moved-away": "已移走", "moved-here": "已移入"
                ][reason] ?? reason
                let actionLabel = ["edit": "修改", "delete": "删除", "add": "新增", "replace": "替换"][action] ?? action
                summary.append("本地原因：\(reasonLabel) · 传入操作：\(actionLabel)")
            }
            for version in node.children where version.name == "version" {
                let label = version.attributes["side"] == "source-left" ? "原基准版本" : "传入版本"
                let kind = version.attributes["kind"] ?? "未知类型"
                let kindLabel = ["file": "文件", "dir": "目录", "none": "节点不存在"][kind] ?? kind
                summary.append("\(label)：/\(version.attributes["path-in-repos"] ?? "") · r\(version.attributes["revision"] ?? "?") · \(kindLabel)")
            }
            for (key, title) in [
                ("prev-base-file", "原基准内容"), ("prev-wc-file", "合并前本地内容"),
                ("cur-base-file", "传入内容"), ("prop-file", "属性冲突说明")
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
    private func conflictMetadataDigest(_ node: XMLNode) throws -> String {
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
            throw SVNError("冲突查看仅支持当前工作副本内的普通文件，不跟随符号链接。")
        }
        return try Data(contentsOf: file.url)
    }

    /// 在确认前读取最终工作内容；只支持单文件内容冲突，不连带接受属性或树冲突。
    public func prepareConflictResolution(_ details: ConflictDetails) async throws -> ConflictResolutionPlan {
        let current = try await conflictDetails(path: details.entry.path, at: details.root)
        guard current.canMarkResolved, current.entry == details.entry,
              current.metadataDigest == details.metadataDigest,
              let working = current.files.first(where: { $0.id == "working" }) else {
            throw SVNError("冲突状态已变化，或包含尚不支持直接标记的属性／树冲突。请重新读取详情。")
        }
        let data = try conflictFileContent(working, at: details.root)
        let text = String(data: data, encoding: .utf8)
        let markers = text?.components(separatedBy: .newlines).contains {
            $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("||||||| ") || $0.hasPrefix(">>>>>>> ")
        } ?? false
        return ConflictResolutionPlan(
            details: details,
            preview: text ?? "当前内容不是 UTF-8 文本（\(data.count) 字节）。请用合适的编辑器检查最终文件后再确认。",
            containsConflictMarkers: markers, contentDigest: SHA256.hash(data: data).description
        )
    }

    /// 确认内容与冲突身份未变化后才采用 working；命令结束后以 SVN 重新读取的状态为准。
    public func resolveConflict(_ plan: ConflictResolutionPlan) async throws -> String {
        let fresh = try await prepareConflictResolution(plan.details)
        guard fresh.contentDigest == plan.contentDigest else {
            throw SVNError("确认期间工作文件内容已变化，尚未标记解决。请重新检查最终内容。")
        }
        try Task.checkCancellation()
        let output = try await command(
            ["resolve", "--accept", "working", "--depth", "empty", "--", try localTarget(plan.details.entry.path)],
            in: plan.details.root
        )
        let entries = try await status(at: plan.details.root)
        guard !entries.contains(where: { $0.path == plan.details.entry.path && $0.isConflict }) else {
            throw SVNError("标记命令已执行，但该文件仍处于冲突状态，请重新检查。\n\(output.stdout)\(output.stderr)")
        }
        return "已保留当前工作文件并标记解决；尚未提交到仓库。\n" + output.stdout + output.stderr
    }

    /// Re-read the working copy before committing; never trust an old UI status snapshot.
    public func commit(
        paths: [String], message: String, at directory: URL,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
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
                in: directory, onOutput: onOutput
            )
            return output.stdout + output.stderr
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SVNError("提交未确认完成，请先查看仓库历史核实结果，勿直接重复提交。\n\n\(error.localizedDescription)")
        }
    }

    /// 只生成待确认清单，不修改文件；目录按 empty 深度处理，结构性目录还原另行支持。
    public func prepareRevert(paths: [String], at directory: URL) async throws -> RevertPlan {
        guard !paths.isEmpty else { throw SVNError("请先选择需要还原的项目。") }
        let paths = Set(paths)
        let current = try await status(at: directory)
        var items: [RevertItem] = []
        for path in paths.sorted() {
            let target = try localTarget(path)
            guard let entry = current.first(where: { $0.path == path }), entry.canRevert else {
                throw SVNError("\(path) 当前不能还原，请刷新状态；冲突需通过冲突处理流程解决。")
            }
            let output = try await command(["info", "--xml", "--", target], in: directory)
            let copy = try SVNXML.info(output.stdout)
            guard copy.root.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else {
                throw SVNError("不能跨工作副本还原：\(path)。")
            }
            let info = try XMLReader.parse(output.stdout).child("entry")
            let isDirectory = info?.attributes["kind"] == "dir"
            if isDirectory, entry.copied || ["deleted", "replaced", "missing"].contains(entry.item) {
                throw SVNError("目录删除、替换、缺失或带历史复制可能影响未选子项，当前不支持直接还原：\(path)。")
            }
            if isDirectory, entry.item == "added" {
                let children = current.filter {
                    $0.path.hasPrefix(path + "/") && !["unversioned", "ignored", "external"].contains($0.item)
                }
                guard children.allSatisfy({ paths.contains($0.path) }) else {
                    throw SVNError("还原新增目录前，请一并选择已纳入版本控制的子项：\(path)。")
                }
            }
            // SVN move 的两端存在元数据关联，不能把其中一端当作独立复制或删除还原。
            let wcInfo = info?.child("wc-info")
            guard wcInfo?.child("moved-from") == nil, wcInfo?.child("moved-to") == nil else {
                throw SVNError("移动操作涉及源路径和目标路径，当前不支持单独还原：\(path)。")
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
                effect = entry.copied ? "撤销复制安排，并删除复制产生的本地文件及其未提交修改。" : "撤销新增安排，保留本地文件或目录；属性修改将丢弃。"
            case "deleted", "missing":
                effect = "恢复工作副本 BASE 版本的文件及属性，取消删除安排；现有本地内容将被覆盖。"
            case "replaced":
                effect = "丢弃替换后的内容与属性，恢复原文件的 BASE 版本。"
            default:
                effect = isDirectory ? "丢弃当前目录的属性修改，不还原未选子项。" : "丢弃未提交的内容与属性修改，恢复工作副本 BASE 版本。"
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
            throw SVNError("确认期间文件或状态发生变化，尚未执行还原。请重新检查还原清单。")
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
            throw SVNError("还原命令已执行，但部分目标仍有未提交修改，请检查状态。\n\(output.stdout)\(output.stderr)")
        }
        return output.stdout + output.stderr
    }

    /// 二进制内容也参与确认快照；读取符号链接本身，不跟随链接读取其他位置的文件。
    private func contentDigest(at url: URL, isDirectory: Bool) throws -> String? {
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
            throw SVNError("还原目标不是普通文件或符号链接：\(url.lastPathComponent)。")
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
