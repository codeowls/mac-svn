import Foundation

public struct FinderBadgeSnapshot: Sendable {
    public let scannedAt: Date
    public let badges: [String: FinderBadge]

    /// 仅明确返回的项目可显示正常；忽略、external、嵌套副本及未扫描子项不推断为正常。
    init(statusXML: String, at root: URL, scannedAt: Date = Date()) throws {
        let tree = try XMLReader.parse(statusXML)
        let states = try SVNXML.status(statusXML)
        let externalFiles = Set(tree.descendants("entry").compactMap { node in
            node.child("wc-status")?.attributes["file-external"] == "true" ? node.attributes["path"] : nil
        })
        var direct: [String: FinderBadge] = [:]
        var excluded = Set<String>()
        for state in states {
            try Task.checkCancellation()
            guard FinderBadgeRequest.validPath(state.path) else { continue }
            let nested = state.item == "unversioned"
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(state.path).appendingPathComponent(".svn").path)
            if ["ignored", "external"].contains(state.item) || externalFiles.contains(state.path) || nested {
                excluded.insert(state.path)
                continue
            }
            let badge: FinderBadge?
            if state.isConflict || ["missing", "obstructed", "incomplete"].contains(state.item) {
                badge = .conflicted
            } else if state.properties == "modified" || ["modified", "deleted", "replaced"].contains(state.item) {
                badge = .modified
            } else {
                switch state.item {
                case "normal":
                    if ["normal", "none"].contains(state.properties) {
                        badge = state.copied ? .added : .normal
                    } else {
                        badge = nil
                    }
                case "added": badge = .added
                case "unversioned": badge = .unversioned
                default: badge = nil
                }
            }
            if let badge { direct[state.path] = badge }
        }
        var badges = direct
        // 只汇总到本次明确扫描到的受控祖先，不给未受控目录里的未知子项生成角标。
        for (path, badge) in direct {
            var parent = path
            while parent != "." {
                parent = (parent as NSString).deletingLastPathComponent
                if parent.isEmpty { parent = "." }
                if let current = badges[parent], !excluded.contains(parent), badge.priority > current.priority {
                    badges[parent] = badge
                }
            }
        }
        self.scannedAt = scannedAt
        self.badges = badges
    }
}

extension SVNClient {
    /// 纯本地完整状态查询，不带 -u，不访问仓库服务器或认证服务。
    public func finderBadgeSnapshot(at root: URL) async throws -> FinderBadgeSnapshot {
        let copy = try await workingCopy(at: root)
        guard copy.root.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
            throw SVNError(L10n.text("请选择工作副本根目录启用访达集成。"))
        }
        let output = try await command(
            ["status", "--xml", "--verbose", "--no-ignore", "--ignore-externals", "--", ".@"], in: root
        )
        try Task.checkCancellation()
        return try FinderBadgeSnapshot(statusXML: output.stdout, at: root)
    }
}
