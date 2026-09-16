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
