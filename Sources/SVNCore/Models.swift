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
        if treeConflict { return "树冲突" }
        if isConflict { return "冲突" }
        let labels = [
            "added": "新增", "modified": "修改", "deleted": "计划删除",
            "replaced": "替换", "unversioned": "未纳入版本控制", "missing": "文件缺失",
            "obstructed": "路径阻塞", "external": "外部工作副本",
            "incomplete": "不完整", "normal": "内容未改", "ignored": "已忽略"
        ]
        let text = labels[item] ?? item
        return properties == "modified" ? "\(text) · 属性修改" : text
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
        "\(path) · r\(revision)" + (isCopySource ? "（复制来源）" : "")
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
        case "A": return copyFromPath == nil ? "新增" : "新增 · 复制"
        case "D": return "删除"
        case "R": return "替换"
        case "M": return propertiesModified == true && textModified == false ? "属性修改" : "修改"
        default: return action
        }
    }
}
