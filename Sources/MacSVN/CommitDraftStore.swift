import Foundation
import SVNCore

struct WorkingCopyDraftKey: Codable, Hashable {
    let path: String
    let repository: String

    init(_ copy: WorkingCopy) {
        path = copy.root.resolvingSymlinksInPath().path
        repository = copy.repositoryURL
    }
}

/// 只保存提交说明，原子写入本机应用数据目录，不保存选中范围、密码或提交计划。
struct CommitDraftStore {
    static let defaultURL = URL.applicationSupportDirectory
        .appendingPathComponent("MacSVN/commit-drafts.json")
    let url: URL

    private struct Record: Codable {
        let key: WorkingCopyDraftKey
        let message: String
    }

    private struct Document: Codable {
        let version: Int
        let records: [Record]
    }

    func message(for key: WorkingCopyDraftKey) throws -> String {
        try read()[key] ?? ""
    }

    func update(_ messages: [WorkingCopyDraftKey: String], removingRoot: String? = nil) throws {
        var stored = try read()
        for (key, message) in messages {
            stored[key] = message.isEmpty ? nil : message
        }
        if let removingRoot {
            stored = stored.filter { $0.key.path != removingRoot }
        }
        var records: [Record] = stored.map { Record(key: $0.key, message: $0.value) }
        records.sort { left, right in
            if left.key.path == right.key.path {
                return left.key.repository < right.key.repository
            }
            return left.key.path < right.key.path
        }
        let data = try JSONEncoder().encode(Document(version: 1, records: records))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func read() throws -> [WorkingCopyDraftKey: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw SVNError(L10n.text("不支持的提交草稿格式。")) }
        var messages: [WorkingCopyDraftKey: String] = [:]
        for record in document.records {
            guard messages[record.key] == nil else { throw SVNError(L10n.text("提交草稿包含重复副本记录。")) }
            messages[record.key] = record.message
        }
        return messages
    }
}
