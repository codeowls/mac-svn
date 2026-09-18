import Foundation
import CryptoKit

public enum FileOperation: String, Sendable {
    case rename, delete

    public var title: String { self == .rename ? "重命名" : "删除" }
}

public struct FileOperationPlan: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let operation: FileOperation
    public let source: String
    public let destination: String?
    public let affectedPaths: [String]
    public let preview: String
    let snapshot: String
}

public struct CommitReviewItem: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let reason: String
    let snapshot: String
}

public struct CommitPlan: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let requestedPaths: [String]
    public let message: String
    public let items: [CommitReviewItem]
    let targets: [String]
}

extension SVNClient {
    /// 展开 SVN 必须一起提交的移动两端、父目录和结构性目录；所有隐含子项先展示再确认。
    public func prepareCommit(paths: [String], message: String, at directory: URL) async throws -> CommitPlan {
        guard !paths.isEmpty else { throw SVNError("请先勾选要提交的项目。") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError("请填写提交说明。")
        }
        let current = try await status(at: directory)
        var reasons: [String: String] = [:]
        for path in Set(paths) {
            _ = try localTarget(path)
            guard current.contains(where: { $0.path == path && $0.canCommit }) else {
                throw SVNError("\(path) 的状态已变化或不可提交，请刷新后检查。")
            }
            reasons[path] = "已勾选"
        }
        var reviewed: [String: CommitReviewItem] = [:]
        var replacedBaseItems: [String: CommitReviewItem] = [:]
        while let next = reasons.sorted(by: { $0.key < $1.key }).first(where: { reviewed[$0.key] == nil }) {
            let path = next.key
            let target = try localTarget(path)
            let infoOutput = try await command(["info", "--xml", "--depth", "empty", "--", target], in: directory)
            let info = try XMLReader.parse(infoOutput.stdout)
            guard let node = info.child("entry") else { throw SVNError("缺少提交项目元数据：\(path)") }
            try requireOperationRoot(node, directory: directory)
            let statusOutput = try await command(
                ["status", "--xml", "--depth", "empty", "--verbose", "--ignore-externals", "--", target], in: directory
            )
            let stateTree = try XMLReader.parse(statusOutput.stdout)
            guard let state = try SVNXML.status(statusOutput.stdout).first, !state.isConflict,
                  state.canCommit || state.item == "normal",
                  !stateTree.descendants("wc-status").contains(where: { $0.attributes["file-external"] == "true" }) else {
                throw SVNError("提交范围中存在不可提交项目：\(path)")
            }
            for key in ["moved-from", "moved-to"] {
                if let other = node.child("wc-info")?.child(key)?.text, !other.isEmpty {
                    _ = try operationPath(other, at: directory)
                    if reasons[other] == nil { reasons[other] = "重命名／移动的另一端：\(path)" }
                }
            }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                if current.contains(where: { $0.path == parent && ["added", "replaced"].contains($0.item) }),
                   reasons[parent] == nil {
                    reasons[parent] = "尚未提交的父目录：\(path)"
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            let isDirectory = node.attributes["kind"] == "dir"
            if isDirectory && (state.copied || ["deleted", "replaced"].contains(state.item)) {
                let descendants = try await command(["info", "--xml", "--depth", "infinity", "--", target], in: directory)
                for child in try XMLReader.parse(descendants.stdout).children where child.name == "entry" {
                    try requireOperationRoot(child, directory: directory)
                    if let childPath = child.attributes["path"], reasons[childPath] == nil {
                        reasons[childPath] = "目录结构操作包含的子项：\(path)"
                    }
                }
            }
            if isDirectory && state.item == "replaced" {
                // 新目录的 info 不含被替换掉的旧子项；从 BASE 列出它们，避免确认清单漏报删除。
                guard let revision = stateTree.descendants("wc-status").first?.attributes["revision"],
                      let number = Int(revision), number >= 0, let url = node.child("url")?.text else {
                    throw SVNError("无法确认被替换目录的原版本：\(path)")
                }
                let oldTree = try await command(
                    ["list", "--xml", "--recursive", "-r", revision, "--", url + "@" + revision], in: directory
                )
                let oldNodes = try XMLReader.parse(oldTree.stdout)
                for child in oldNodes.descendants("entry") {
                    guard let name = child.child("name")?.text else { throw SVNError("BASE 目录缺少子项名称。") }
                    let oldPath = path + "/" + name
                    replacedBaseItems[oldPath] = CommitReviewItem(
                        path: oldPath, reason: "目录替换将移除或替换的原 BASE 子项：\(path)",
                        snapshot: try conflictMetadataDigest(child)
                    )
                }
            }
            let properties = try await command(
                ["proplist", "--xml", "--verbose", "--depth", "empty"]
                    + (state.item == "deleted" ? ["-r", "BASE"] : []) + ["--", target], in: directory
            )
            let content = try contentDigest(at: directory.appendingPathComponent(path), isDirectory: isDirectory) ?? ""
            let snapshot = try conflictMetadataDigest(info) + conflictMetadataDigest(stateTree)
                + conflictMetadataDigest(XMLReader.parse(properties.stdout)) + content
            reviewed[path] = CommitReviewItem(path: path, reason: next.value, snapshot: snapshot)
        }
        let targets = reviewed.keys.sorted()
        for (path, oldItem) in replacedBaseItems {
            if let newItem = reviewed[path] {
                reviewed[path] = CommitReviewItem(
                    path: path, reason: newItem.reason + "；替换原 BASE 子项",
                    snapshot: newItem.snapshot + oldItem.snapshot
                )
            } else {
                reviewed[path] = oldItem
            }
        }
        return CommitPlan(
            root: directory, requestedPaths: Set(paths).sorted(), message: message,
            items: reviewed.values.sorted { $0.path < $1.path }, targets: targets
        )
    }

    /// 再次读取确认清单；内容或关联范围改变时要求重审，不会自动扩大最终提交范围。
    public func commit(_ plan: CommitPlan, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let fresh = try await prepareCommit(paths: plan.requestedPaths, message: plan.message, at: plan.root)
        guard fresh.items == plan.items, fresh.targets == plan.targets else {
            throw SVNError("确认期间提交内容或范围发生变化，尚未提交。请重新检查。")
        }
        try Task.checkCancellation()
        do {
            let output = try await command(
                ["commit", "--depth", "empty", "--message", plan.message, "--"] + plan.targets.map(localTarget),
                in: plan.root, onOutput: onOutput
            )
            return output.stdout + output.stderr
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SVNError("提交未确认完成，请先查看仓库历史核实结果，勿直接重复提交。\n\n\(error.localizedDescription)")
        }
    }

    /// 对整个操作范围生成快照：版本状态、属性和实际文件都必须与最终确认一致。
    public func prepareFileOperation(
        _ operation: FileOperation, path: String, newName: String = "", at directory: URL
    ) async throws -> FileOperationPlan {
        let source = try operationPath(path, at: directory)
        let target = try localTarget(source)
        let infoOutput = try await command(["info", "--xml", "--depth", "infinity", "--", target], in: directory)
        let info = try XMLReader.parse(infoOutput.stdout)
        guard let first = info.child("entry"), first.child("wc-info")?.child("schedule")?.text != "delete" else {
            throw SVNError("此项目已经计划删除，请刷新后检查。")
        }
        for entry in info.children where entry.name == "entry" {
            try requireOperationRoot(entry, directory: directory)
        }
        let statusOutput = try await command(
            ["status", "--xml", "--verbose", "--no-ignore", "--ignore-externals", "--", target], in: directory
        )
        let statuses = try SVNXML.status(statusOutput.stdout)
        guard !statuses.contains(where: {
            $0.isConflict || ["external", "obstructed", "incomplete"].contains($0.item)
        }) else { throw SVNError("范围中存在冲突、外部副本或不完整项目，请先单独处理。") }
        let statusTree = try XMLReader.parse(statusOutput.stdout)
        guard !statusTree.descendants("wc-status").contains(where: {
            $0.attributes["file-external"] == "true" || $0.attributes["switched"] == "true"
        }) else { throw SVNError("范围中存在外部文件或已切换的目录，请单独处理。") }
        var destination: String?
        if operation == .rename {
            guard !newName.isEmpty, ![".", "..", ".svn"].contains(newName.lowercased()),
                  !newName.contains("/"), !newName.contains("\0") else {
                throw SVNError("请输入单个文件或目录名称，不能包含斜杠、空字符或 .svn。")
            }
            let parent = (source as NSString).deletingLastPathComponent
            let result = parent.isEmpty ? newName : parent + "/" + newName
            guard result != source else { throw SVNError("新名称与原名称相同。") }
            let url = directory.appendingPathComponent(result)
            // 包括断开的符号链接；绝不把已存在的目录当作移动目的文件夹。
            do {
                _ = try FileManager.default.attributesOfItem(atPath: url.path)
                throw SVNError("目标路径已存在，请选择其他名称：\(result)")
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                // 目标尚不存在，符合重命名要求；其他读取错误保持原样上报。
            }
            let current = try await status(at: directory, includeIgnored: true)
            guard !current.contains(where: { $0.path == result }) else {
                throw SVNError("目标路径已有 SVN 操作记录，请先处理：\(result)")
            }
            destination = result
        }
        let physical = try physicalSnapshot(path: source, at: directory)
        let versioned = info.children.filter { $0.name == "entry" }.compactMap { $0.attributes["path"] }
        let affected = Set(versioned + physical.map { $0.path }).sorted()
        let properties = try await command(
            ["proplist", "--xml", "--verbose", "--depth", "infinity", "--", target], in: directory
        )
        let snapshot = try conflictMetadataDigest(info) + conflictMetadataDigest(statusTree)
            + conflictMetadataDigest(XMLReader.parse(properties.stdout))
            + physical.map { $0.path + "\0" + $0.digest }.joined(separator: "\n")
        let diff = try await command(["diff", "--internal-diff", "--old", target], in: directory)
        let statusSummary = statuses.map { "\($0.path) · \($0.label)" }.joined(separator: "\n")
        return FileOperationPlan(
            root: directory, operation: operation, source: source, destination: destination,
            affectedPaths: affected, preview: statusSummary + "\n\n" + diff.stdout, snapshot: snapshot
        )
    }

    /// 只在确认快照未变化时执行；删除明确包括列表中的未受控／忽略文件，不隐式提交。
    public func performFileOperation(_ plan: FileOperationPlan) async throws -> String {
        let fresh = try await prepareFileOperation(
            plan.operation, path: plan.source,
            newName: plan.destination.map { ($0 as NSString).lastPathComponent } ?? "", at: plan.root
        )
        guard fresh.snapshot == plan.snapshot, fresh.affectedPaths == plan.affectedPaths else {
            throw SVNError("确认期间文件、属性或状态已变化，尚未执行。请重新检查操作范围。")
        }
        try Task.checkCancellation()
        let arguments: [String]
        if let destination = plan.destination {
            // svn move 的目标不是 peg 路径，不能像源路径那样附加 @。
            arguments = ["move", "--", try localTarget(plan.source), "./" + destination]
        } else {
            arguments = ["delete", "--force", "--", try localTarget(plan.source)]
        }
        let output = try await command(arguments, in: plan.root)
        _ = try await status(at: plan.root)
        return "\(plan.operation.title)已完成，尚未提交到仓库。\n" + output.stdout + output.stderr
    }

    /// 只处理工作副本内的明确相对路径；不通过父目录符号链接进入其他位置。
    func operationPath(_ path: String, at directory: URL) throws -> String {
        _ = try localTarget(path)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0.lowercased() == ".svn" }) else {
            throw SVNError("不能操作工作副本根目录、元数据或非规范路径。")
        }
        let parent = directory.appendingPathComponent(path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = directory.resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw SVNError("路径不属于当前工作副本。")
        }
        return path
    }

    func requireOperationRoot(_ node: XMLNode, directory: URL) throws {
        guard let root = node.child("wc-info")?.child("wcroot-abspath")?.text,
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else {
            throw SVNError("不能操作嵌套工作副本，请单独打开该副本。")
        }
    }

    /// 枚举磁盘内容而非仅 svn status；被忽略的文件也会被目录删除，必须列入确认。
    func physicalSnapshot(path: String, at directory: URL) throws -> [(path: String, digest: String)] {
        let url = directory.appendingPathComponent(path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return []
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeDirectory {
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            guard !children.contains(where: { $0.lowercased() == ".svn" }) else {
                throw SVNError("操作范围包含嵌套工作副本：\(path)")
            }
            return try [(path, "directory")] + children.flatMap {
                try physicalSnapshot(path: path + "/" + $0, at: directory)
            }
        }
        guard type == .typeRegular || type == .typeSymbolicLink else {
            throw SVNError("不支持操作此特殊文件：\(path)")
        }
        return [(path, (type == .typeSymbolicLink ? "link:" : "file:")
            + (try contentDigest(at: url, isDirectory: false) ?? "missing"))]
    }
}
