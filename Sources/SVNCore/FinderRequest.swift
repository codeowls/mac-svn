import Foundation

/// Finder messages express intent only. The host must confirm every write operation.
public struct FinderRequest: Sendable, Equatable {
    public enum Action: String, Sendable {
        case open, commit, update, history, diff
    }

    public let action: Action
    public let paths: [String]

    public init(url: URL) throws {
        guard let message = URLComponents(url: url, resolvingAgainstBaseURL: false),
              message.scheme == "macsvn", message.host == "finder",
              message.user == nil, message.password == nil, message.port == nil,
              message.path.isEmpty, message.fragment == nil,
              let items = message.queryItems,
              items.allSatisfy({ $0.name == "action" || $0.name == "path" }),
              items.filter({ $0.name == "action" }).count == 1,
              let value = items.first(where: { $0.name == "action" })?.value,
              let action = Action(rawValue: value) else {
            throw SVNError(L10n.text("无效的访达操作请求。"))
        }
        let selections = items.filter { $0.name == "path" }
        guard !selections.isEmpty,
              selections.allSatisfy({ item in
                  guard let path = item.value else { return false }
                  return path.hasPrefix("/") && !path.contains("\0")
              }) else {
            throw SVNError(L10n.text("访达请求必须包含绝对路径。"))
        }
        self.action = action
        var seen = Set<String>()
        self.paths = selections.compactMap(\.value).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }.filter { seen.insert($0).inserted }
    }

    /// Match whole path components, so selecting “src” never includes “src-other”.
    public static func contains(_ entry: String, in selection: String) -> Bool {
        selection == "." || entry == selection || entry.hasPrefix(selection + "/")
    }
}

public struct FinderSelection: Sendable {
    public let workingCopy: WorkingCopy
    public let relativePaths: [String]
}

extension SVNClient {
    /// Locate each selection independently; never silently choose one of several working copies.
    public func resolveFinderSelection(_ request: FinderRequest) async throws -> FinderSelection {
        var roots: [URL] = []
        var paths: [String] = []
        for path in request.paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw SVNError(L10n.text("访达所选路径已不存在：%@", path))
            }
            var directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
            // Unversioned descendants still belong to their nearest working copy.
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".svn").path) {
                let parent = directory.deletingLastPathComponent()
                guard parent != directory else {
                    throw SVNError(L10n.text("所选路径不在 SVN 工作副本中：%@", path))
                }
                directory = parent
            }
            let root = directory.resolvingSymlinksInPath().standardizedFileURL
            // Preserve the final component: SVN can version symbolic links themselves.
            let selected = url == directory ? root : url.deletingLastPathComponent()
                .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
            guard selected.path == root.path || selected.path.hasPrefix(root.path + "/") else {
                throw SVNError(L10n.text("所选路径超出工作副本范围：%@", path))
            }
            roots.append(root)
            paths.append(selected == root ? "." : String(selected.path.dropFirst(root.path.count + 1)))
        }
        guard let root = roots.first, roots.allSatisfy({ $0 == root }) else {
            throw SVNError(L10n.text("所选项目属于多个工作副本，请分别操作。"))
        }
        let copy = try await workingCopy(at: root)
        guard copy.root.resolvingSymlinksInPath() == root else {
            throw SVNError(L10n.text("工作副本位置已变化，请重新从访达选择。"))
        }
        return FinderSelection(workingCopy: copy, relativePaths: paths)
    }
}
