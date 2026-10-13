import Foundation

public struct FileReview: Sendable {
    public let path: String
    public let snapshot: String
    public let diff: String
}

extension SVNClient {
    /// 差异前后核对同一份快照；编辑中的内容不能误标为已经审阅。
    public func fileReview(path: String, at root: URL) async throws -> FileReview {
        let before = try await reviewSnapshot(path: path, at: root)
        let text = try await diff(path: path, at: root)
        let after = try await reviewSnapshot(path: path, at: root)
        guard before == after else {
            throw SVNError(L10n.text("读取期间项目内容或属性已变化，请重新读取差异。"))
        }
        return FileReview(path: path, snapshot: after, diff: text)
    }

    /// 与提交确认使用相同的元数据、属性及原始字节摘要，二进制和属性修改同样失效。
    public func reviewSnapshot(path: String, at root: URL) async throws -> String {
        let target = try localTarget(path)
        let infoOutput = try await command(["info", "--xml", "--depth", "empty", "--", target], in: root)
        let info = try XMLReader.parse(infoOutput.stdout)
        guard let node = info.child("entry") else {
            throw SVNError(L10n.text("缺少审阅项目元数据：%@", path))
        }
        try requireOperationRoot(node, directory: root)
        let statusOutput = try await command(
            ["status", "--xml", "--depth", "empty", "--verbose", "--ignore-externals", "--", target], in: root
        )
        let status = try XMLReader.parse(statusOutput.stdout)
        guard let state = try SVNXML.status(statusOutput.stdout).first,
              state.canCommit || state.item == "normal",
              !state.isConflict,
              !status.descendants("wc-status").contains(where: { $0.attributes["file-external"] == "true" }) else {
            throw SVNError(L10n.text("%@ 当前状态不能标记审阅，请刷新后检查。", path))
        }
        let properties = try await command(
            ["proplist", "--xml", "--verbose", "--depth", "empty"]
                + (state.item == "deleted" ? ["-r", "BASE"] : []) + ["--", target], in: root
        )
        let content = try contentDigest(at: root.appendingPathComponent(path), isDirectory: node.attributes["kind"] == "dir") ?? ""
        return try conflictMetadataDigest(info) + conflictMetadataDigest(status)
            + conflictMetadataDigest(XMLReader.parse(properties.stdout)) + content
    }
}
