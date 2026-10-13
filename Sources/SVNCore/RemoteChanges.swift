import Foundation

public struct RemoteChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let item: String
    public let properties: String
    public let localOverlaps: [StatusEntry]

    public var label: String {
        let labels = [
            "added": L10n.text("远端新增"), "deleted": L10n.text("远端删除"),
            "modified": L10n.text("远端修改"), "replaced": L10n.text("远端替换")
        ]
        let content = labels[item]
        if properties == "modified" {
            return content.map { $0 + L10n.text(" · 属性修改") } ?? L10n.text("远端属性修改")
        }
        return content ?? item
    }
}

public struct RemoteChanges: Sendable {
    public let root: URL
    public let revision: String
    public let checkedAt: Date
    public let items: [RemoteChange]

    /// 同一份状态 XML 同时提供远端和本地信息，避免用不同时间的快照猜测重叠。
    static func parse(_ xml: String, at root: URL) throws -> RemoteChanges {
        let tree = try XMLReader.parse(xml)
        guard tree.name == "status", let revision = tree.descendants("against").first?.attributes["revision"],
              let number = Int(revision), number >= 0 else {
            throw SVNError(L10n.text("远端状态响应缺少有效的检查版本号。"))
        }
        let local = try SVNXML.status(xml).filter {
            $0.item != "none" && $0.item != "external" && ($0.item != "normal" || $0.properties == "modified" || $0.isConflict)
        }
        var changes: [RemoteChange] = []
        for entry in tree.descendants("entry") {
            guard let remote = entry.child("repos-status") else { continue }
            guard let path = entry.attributes["path"], let item = remote.attributes["item"],
                  let properties = remote.attributes["props"],
                  ["none", "normal", "added", "deleted", "modified", "replaced"].contains(item),
                  ["none", "normal", "modified"].contains(properties) else {
                throw SVNError(L10n.text("远端状态响应缺少有效的项目状态。"))
            }
            guard !["none", "normal"].contains(item) || properties == "modified" else { continue }
            let overlaps = local.filter { candidate in
                if candidate.path == path { return true }
                if ["deleted", "replaced"].contains(item), FinderRequest.contains(candidate.path, in: path) {
                    return true
                }
                return ["deleted", "replaced", "unversioned", "ignored"].contains(candidate.item)
                    && FinderRequest.contains(path, in: candidate.path)
            }
            changes.append(RemoteChange(path: path, item: item, properties: properties, localOverlaps: overlaps))
        }
        return RemoteChanges(
            root: root, revision: revision, checkedAt: Date(),
            items: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }
}

extension SVNClient {
    /// 只检查当前检出范围，不下载或修改文件；外部副本仍需单独处理。
    public func remoteChanges(at root: URL) async throws -> RemoteChanges {
        let output = try await command(
            ["status", "--show-updates", "--verbose", "--xml", "--no-ignore", "--ignore-externals", "--", ".@"], in: root
        )
        return try RemoteChanges.parse(output.stdout, at: root)
    }
}
