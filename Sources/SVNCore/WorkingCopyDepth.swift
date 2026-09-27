import Foundation

public struct WorkingCopyDepth: Identifiable, Sendable, Equatable {
    public var id: String { root.appendingPathComponent(path).path }
    public let root: URL
    public let path: String
    public let depth: CheckoutDepth
}

public struct DepthChangePlan: Identifiable, Sendable {
    public let id = UUID()
    public let directory: WorkingCopyDepth
    public let depth: CheckoutDepth
    public let removedPaths: [String]
    let snapshot: String
}

extension SVNClient {
    /// 深度只从本地 SVN 元数据读取；目标必须是当前副本中正常的受控目录。
    public func workingCopyDepth(path: String = ".", at root: URL) async throws -> WorkingCopyDepth {
        if path != "." { _ = try operationPath(path, at: root) }
        let target = try localTarget(path)
        let output = try await command(["info", "--xml", "--depth", "empty", "--", target], in: root)
        guard let node = try XMLReader.parse(output.stdout).child("entry"),
              node.attributes["kind"] == "dir",
              node.child("wc-info")?.child("schedule")?.text == "normal",
              let value = node.child("wc-info")?.child("depth")?.text,
              let depth = CheckoutDepth(rawValue: value) else {
            throw SVNError(L10n.text("请选择已检出的正常受控目录；新增、删除或替换目录不能调整深度。"))
        }
        try requireOperationRoot(node, directory: root)
        let outputStatus = try await command(
            ["status", "--xml", "--verbose", "--depth", "empty", "--ignore-externals", "--", target], in: root
        )
        guard let state = try SVNXML.status(outputStatus.stdout).first,
              state.item == "normal", !state.isConflict else {
            throw SVNError(L10n.text("目录存在冲突或异常状态，请处理后再调整深度。"))
        }
        return WorkingCopyDepth(root: root, path: path, depth: depth)
    }

    /// 展开缩小深度会移除的受控节点，并拒绝移除范围内的本地修改或额外文件。
    public func prepareDepthChange(
        path: String = ".", depth: CheckoutDepth, at root: URL
    ) async throws -> DepthChangePlan {
        let directory = try await workingCopyDepth(path: path, at: root)
        let target = try localTarget(path)
        let info = try await command(["info", "--xml", "--depth", "infinity", "--", target], in: root)
        let tree = try XMLReader.parse(info.stdout)
        var removed: [String] = []
        for node in tree.children where node.name == "entry" {
            try Task.checkCancellation()
            try requireOperationRoot(node, directory: root)
            guard let childPath = node.attributes["path"], let kind = node.attributes["kind"] else {
                throw SVNError(L10n.text("SVN 目录响应缺少路径或类型。"))
            }
            if childPath == path { continue }
            let prefix = path == "." ? "" : path + "/"
            guard childPath.hasPrefix(prefix) else {
                throw SVNError(L10n.text("路径不属于当前工作副本。"))
            }
            let levels = childPath.dropFirst(prefix.count).split(separator: "/").count
            let excluded: Bool
            switch depth {
            case .infinity: excluded = false
            case .immediates: excluded = levels > 1
            case .files: excluded = levels > 1 || kind == "dir"
            case .empty: excluded = true
            }
            if excluded { removed.append(childPath) }
        }
        removed.sort()
        let status = try await command(
            ["status", "--xml", "--verbose", "--no-ignore", "--depth", "infinity", "--ignore-externals", "--", target],
            in: root
        )
        let statusTree = try XMLReader.parse(status.stdout)
        let removedSet = Set(removed)
        let removalRoots = removed.filter { !removedSet.contains(($0 as NSString).deletingLastPathComponent) }
        func isRemoved(_ path: String) -> Bool {
            var ancestor = path
            while !ancestor.isEmpty && !removedSet.contains(ancestor) {
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return !ancestor.isEmpty
        }
        for entry in try SVNXML.status(status.stdout) {
            let hasLocalChange = entry.item != "normal" || entry.properties == "modified"
                || entry.isConflict || entry.copied
            if isRemoved(entry.path) && hasLocalChange {
                throw SVNError(L10n.text("缩小范围包含本地修改、未受控或异常项目：%@。请先处理，文件未被移除。", entry.path))
            }
        }
        for node in statusTree.descendants("entry") {
            if let path = node.attributes["path"], isRemoved(path),
               node.child("wc-status")?.attributes["file-external"] == "true" {
                throw SVNError(L10n.text("缩小范围包含外部文件：%@。请先单独处理外部引用。", path))
            }
        }
        // 磁盘快照补足 status 不展开的忽略目录和嵌套副本；确认后重新检查同一范围。
        var physical = ""
        for removalRoot in removalRoots {
            try Task.checkCancellation()
            for item in try physicalSnapshot(path: removalRoot, at: root) {
                guard removedSet.contains(item.path) else {
                    throw SVNError(L10n.text("缩小范围包含本地修改、未受控或异常项目：%@。请先处理，文件未被移除。", item.path))
                }
                physical += "\(item.path.utf8.count):\(item.path)\(item.digest)\n"
            }
        }
        let snapshot = try conflictMetadataDigest(tree) + conflictMetadataDigest(statusTree) + physical
        return DepthChangePlan(directory: directory, depth: depth, removedPaths: removed, snapshot: snapshot)
    }

    /// 确认后重读范围，再持久化深度并更新；不强制覆盖、不处理 externals、不自动重试。
    public func changeDepth(
        _ plan: DepthChangePlan, onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let fresh = try await prepareDepthChange(
            path: plan.directory.path, depth: plan.depth, at: plan.directory.root
        )
        guard fresh.directory == plan.directory, fresh.removedPaths == plan.removedPaths,
              fresh.snapshot == plan.snapshot else {
            throw SVNError(L10n.text("确认期间目录状态或范围发生变化，尚未调整深度。请重新检查。"))
        }
        try Task.checkCancellation()
        let output = try await command(
            ["update", "--set-depth", plan.depth.rawValue, "--accept", "postpone", "--ignore-externals",
             "--", try localTarget(plan.directory.path)],
            in: plan.directory.root, onOutput: onOutput
        )
        let actual = try await workingCopyDepth(path: plan.directory.path, at: plan.directory.root)
        guard actual.depth == plan.depth else {
            throw SVNError(L10n.text("操作已结束，但目录实际深度与目标不一致，请重新检查。"))
        }
        let summary = L10n.text("\n当前目录深度：%@。", actual.depth.label)
        onOutput?(summary)
        return output.stdout + output.stderr + summary
    }
}
