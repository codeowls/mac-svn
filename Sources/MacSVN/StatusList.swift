import Foundation
import SVNCore

enum StatusFilter: String, CaseIterable {
    case all, modified, added, conflicts

    var title: String {
        switch self {
        case .all: return L10n.text("全部状态")
        case .modified: return L10n.text("修改")
        case .added: return L10n.text("新增")
        case .conflicts: return L10n.text("冲突")
        }
    }

    func matches(_ entry: StatusEntry) -> Bool {
        switch self {
        case .all: return true
        case .modified:
            return !entry.isConflict && (entry.item == "modified" || entry.item == "replaced" || (entry.item == "normal" && entry.properties == "modified"))
        case .added: return !entry.isConflict && entry.item == "added"
        case .conflicts: return entry.isConflict
        }
    }
}

enum StatusListRow: Identifiable {
    case directory(path: String, count: Int)
    case entry(StatusEntry)

    var id: String {
        switch self {
        case .directory(let path, _): return "directory:" + path
        case .entry(let entry): return "entry:" + entry.path
        }
    }

    /// 分组只改变列表呈现，不参与提交选中范围或 SVN 路径展开。
    static func make(entries: [StatusEntry], grouped: Bool, collapsed: Set<String>) -> [StatusListRow] {
        guard grouped else { return entries.map(StatusListRow.entry) }
        let groups = Dictionary(grouping: entries) { entry in
            let parent = (entry.path as NSString).deletingLastPathComponent
            return parent.isEmpty || parent == "." ? "." : parent
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { directory in
            let children = groups[directory]!.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            var rows: [StatusListRow] = [.directory(path: directory, count: children.count)]
            if !collapsed.contains(directory) { rows += children.map(StatusListRow.entry) }
            return rows
        }
    }
}
