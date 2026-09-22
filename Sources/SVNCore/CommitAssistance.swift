import Foundation

public enum CommitChange: CaseIterable, Sendable {
    case added, modified, deleted, replaced, properties, included

    init(_ entry: StatusEntry) {
        switch entry.item {
        case "added": self = .added
        case "modified": self = entry.copied ? .added : .modified
        case "deleted": self = .deleted
        case "replaced": self = .replaced
        default:
            if entry.copied {
                self = .added
            } else if entry.properties == "modified" {
                self = .properties
            } else {
                self = .included
            }
        }
    }

    public var label: String {
        switch self {
        case .added: L10n.text("新增")
        case .modified: L10n.text("修改")
        case .deleted: L10n.text("计划删除")
        case .replaced: L10n.text("替换")
        case .properties: L10n.text("仅属性修改")
        case .included: L10n.text("结构关联项")
        }
    }
}

public struct CommitChangeCount: Identifiable, Sendable {
    public var id: CommitChange { change }
    public let change: CommitChange
    public let count: Int
}

public struct CommitAdvisory: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

/// 只使用提交快照的状态和文件名提供建议；不读取额外文件，也不改变提交目标。
public struct CommitAssistance: Sendable {
    public let changes: [CommitChangeCount]
    public let fileCount: Int
    public let directoryCount: Int
    public let nearbyNewItems: [CommitAdvisory]
    public let temporaryItems: [CommitAdvisory]

    public var hasSuggestions: Bool {
        !nearbyNewItems.isEmpty || !temporaryItems.isEmpty
    }

    init(items: [CommitReviewItem], current: [StatusEntry]) {
        changes = CommitChange.allCases.compactMap { change in
            let count = items.filter { $0.change == change }.count
            return count == 0 ? nil : CommitChangeCount(change: change, count: count)
        }
        directoryCount = items.filter(\.isDirectory).count
        fileCount = items.count - directoryCount

        let included = Set(items.map(\.path))
        let activeItems = items.filter { $0.change != .deleted }
        let parents = Set(activeItems.map { Self.parent(of: $0.path) })
        let directories = activeItems.filter(\.isDirectory).map(\.path)
        nearbyNewItems = current.filter { entry in
            guard ["unversioned", "added"].contains(entry.item), !included.contains(entry.path) else {
                return false
            }
            return parents.contains(Self.parent(of: entry.path)) || directories.contains { directory in
                directory == "." || entry.path.hasPrefix(directory + "/")
            }
        }.sorted { $0.path < $1.path }.map { entry in
            CommitAdvisory(
                path: entry.path,
                reason: entry.item == "unversioned"
                    ? L10n.text("尚未纳入版本控制，不会随本次提交上传。")
                    : L10n.text("已安排新增，但未包含在本次提交范围中。")
            )
        }

        // 仅提示新增／替换内容，避免对仓库中已有的同名业务文件反复报警。
        temporaryItems = items.compactMap { item in
            guard !item.isDirectory, [.added, .replaced].contains(item.change),
                  let reason = Self.temporaryReason(for: item.path) else { return nil }
            return CommitAdvisory(path: item.path, reason: reason)
        }.sorted { $0.path < $1.path }
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    /// 使用明确、保守的文件名特征；不将日志、配置文件或整个构建目录一概判为临时文件。
    private static func temporaryReason(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if [".ds_store", "thumbs.db", "desktop.ini"].contains(name) {
            return L10n.text("名称符合系统目录元数据文件的特征，请确认是否需要共享。")
        }
        if name.hasPrefix("~$") || name.hasPrefix(".#") || name.hasSuffix(".swp") || name.hasSuffix(".swo") {
            return L10n.text("名称符合编辑器或 Office 临时文件的特征，请确认是否需要提交。")
        }
        if name.hasSuffix(".tmp") || name.hasSuffix(".temp") || name.hasSuffix(".bak") || name.hasSuffix("~") {
            return L10n.text("名称符合临时或备份文件的特征；仅凭名称判断，请自行核实。")
        }
        return nil
    }
}
