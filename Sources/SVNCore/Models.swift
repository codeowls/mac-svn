import Foundation

public struct WorkingCopy: Sendable {
    public let root: URL
    public let repositoryURL: String
    public let revision: String
}

public struct RepositoryEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let isDirectory: Bool
    public let revision: String
    public let author: String
}

public struct RepositoryLocation: Sendable, Equatable {
    public let url: String
    public let rootURL: String
    public let revision: String
}

/// SVN 检出范围，原始值直接对应 --depth 参数。
public enum CheckoutDepth: String, CaseIterable, Sendable {
    case infinity
    case immediates
    case files
    case empty

    public var label: String {
        switch self {
        case .infinity: return L10n.text("全递归")
        case .immediates: return L10n.text("直接子节点，包含文件夹")
        case .files: return L10n.text("仅文件")
        case .empty: return L10n.text("仅此项")
        }
    }

    public var explanation: String {
        switch self {
        case .infinity: return L10n.text("检出全部文件及所有层级的子目录。")
        case .immediates: return L10n.text("检出当前层文件和直接子目录，不下载子目录中的内容。")
        case .files: return L10n.text("仅检出当前层文件，不下载子目录。")
        case .empty: return L10n.text("仅建立当前目录的工作副本，不下载目录中的文件和子目录。")
        }
    }
}

public struct CheckoutInspection: Sendable {
    public let directory: URL
    public let workingCopy: WorkingCopy?
    public let summary: String
    public let guidance: String
}

public struct StatusEntry: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let item: String
    public let properties: String
    public let treeConflict: Bool
    public let copied: Bool

    public var isConflict: Bool {
        treeConflict || item == "conflicted" || properties == "conflicted"
    }

    public var canCommit: Bool {
        !isConflict && (
            ["added", "modified", "deleted", "replaced"].contains(item)
            || (item == "normal" && properties == "modified")
        )
    }

    public var canReadHistory: Bool {
        !["unversioned", "ignored", "added", "external", "obstructed", "incomplete"].contains(item)
    }

    public var canRevert: Bool {
        !isConflict && (["added", "modified", "deleted", "replaced", "missing"].contains(item)
            || (item == "normal" && properties == "modified"))
    }

    public var label: String {
        if treeConflict { return L10n.text("树冲突") }
        if isConflict { return L10n.text("冲突") }
        let labels = [
            "added": L10n.text("新增"), "modified": L10n.text("修改"), "deleted": L10n.text("计划删除"),
            "replaced": L10n.text("替换"), "unversioned": L10n.text("未纳入版本控制"), "missing": L10n.text("文件缺失"),
            "obstructed": L10n.text("路径阻塞"), "external": L10n.text("外部工作副本"),
            "incomplete": L10n.text("不完整"), "normal": L10n.text("内容未改"), "ignored": L10n.text("已忽略")
        ]
        let text = labels[item] ?? item
        return properties == "modified" ? L10n.text("%@ · 属性修改", text) : text
    }
}

public struct LogEntry: Identifiable, Sendable {
    public var id: String { revision }
    public let revision: String
    public let author: String
    public let date: String
    public let message: String
    public let changedPaths: [LogChangedPath]
}

public struct HistoryPage: Sendable {
    public let entries: [LogEntry]
    public let nextBeforeRevision: Int?
}

public struct HistoricalDiff: Sendable {
    public let oldLabel: String
    public let newLabel: String
    public let text: String
}

public struct HistoricalFileVersion: Sendable, Equatable {
    public let path: String
    public let revision: Int
    public let isCopySource: Bool

    public var label: String {
        "\(path) · r\(revision)" + (isCopySource ? L10n.text("（复制来源）") : "")
    }

    public var suggestedFilename: String {
        let name = URL(fileURLWithPath: path)
        let suffix = name.pathExtension
        let base = suffix.isEmpty ? name.lastPathComponent : name.deletingPathExtension().lastPathComponent
        return "\(base)-r\(revision)" + (suffix.isEmpty ? "" : ".\(suffix)")
    }
}

public struct HistoricalFileVersions: Sendable {
    public let before: HistoricalFileVersion?
    public let after: HistoricalFileVersion?
}

public struct DirectoryIgnoreSettings: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let path: String
    public let patterns: String?
}

public struct RevertPlan: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let items: [RevertItem]
}

public struct ConflictFile: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let url: URL
}

public struct ConflictDetails: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let entry: StatusEntry
    public let summary: [String]
    public let files: [ConflictFile]
    public let canMarkResolved: Bool
    let metadataDigest: String
}

public struct ConflictResolutionPlan: Identifiable, Sendable {
    public let id = UUID()
    public let details: ConflictDetails
    public let preview: String
    public let containsConflictMarkers: Bool
    let contentDigest: String
}

public struct RevertItem: Identifiable, Sendable, Equatable {
    public var id: String { entry.path }
    public let entry: StatusEntry
    public let isDirectory: Bool
    public let effect: String
    public let preview: String
    let baseRevision: String
    let properties: String
    let contentDigest: String?
}

/// 三个条件同时匹配，只筛选已经读取的记录；路径包含该提交返回的所有变更项。
public struct HistoryFilter: Sendable, Equatable {
    public var author = ""
    public var message = ""
    public var path = ""

    public init() {}

    public var isEmpty: Bool {
        [author, message, path].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func matches(_ entry: LogEntry) -> Bool {
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return (author.isEmpty || entry.author.localizedCaseInsensitiveContains(author))
            && (message.isEmpty || entry.message.localizedCaseInsensitiveContains(message))
            && (path.isEmpty || entry.changedPaths.contains { $0.path.localizedCaseInsensitiveContains(path) })
    }
}

public struct LogChangedPath: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let action: String
    public let kind: String?
    public let copyFromPath: String?
    public let copyFromRevision: String?
    public let textModified: Bool?
    public let propertiesModified: Bool?

    public var label: String {
        switch action {
        case "A": return copyFromPath == nil ? L10n.text("新增") : L10n.text("新增 · 复制")
        case "D": return L10n.text("删除")
        case "R": return L10n.text("替换")
        case "M": return propertiesModified == true && textModified == false ? L10n.text("属性修改") : L10n.text("修改")
        default: return action
        }
    }
}
