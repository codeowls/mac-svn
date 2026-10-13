import Foundation
import Combine
import SVNCore

/// 审阅标记按副本隔离且仅在当前会话保留；最终提交仍由既有范围复核负责。
@MainActor
final class FileReviewState: ObservableObject {
    @Published private(set) var snapshots: [String: String] = [:]
    @Published private(set) var displayed: FileReview?
    @Published private(set) var queue: [String] = []
    @Published var error: String?

    func restore(_ snapshots: [String: String]) {
        self.snapshots = snapshots
        displayed = nil
        queue = []
        error = nil
    }

    func begin(paths: [String]) {
        queue = Array(Set(paths)).sorted()
        displayed = nil
        error = nil
    }

    func display(_ review: FileReview?) {
        displayed = review
        error = nil
        if let review, let previous = snapshots[review.path], previous != review.snapshot {
            snapshots.removeValue(forKey: review.path)
        }
    }

    func mark(_ review: FileReview, matching snapshot: String) throws {
        guard displayed?.path == review.path, displayed?.snapshot == review.snapshot,
              snapshot == review.snapshot else {
            snapshots.removeValue(forKey: review.path)
            throw SVNError(L10n.text("项目已变化，请重新读取差异后再标记审阅。"))
        }
        snapshots[review.path] = snapshot
    }

    func unmark(_ path: String) {
        snapshots.removeValue(forKey: path)
    }

    /// 刷新和重新打开副本时核对现值；失效标记不能恢复成已审阅。
    func validate(using client: SVNClient, at root: URL) async throws -> [String: String] {
        var valid: [String: String] = [:]
        let original = snapshots
        guard !original.isEmpty else { return valid }
        let current = try await client.status(at: root, includeUnchanged: true)
        for (path, snapshot) in original {
            guard current.contains(where: { $0.path == path && !$0.isConflict && ($0.canCommit || $0.item == "normal") }) else {
                continue
            }
            if try await client.reviewSnapshot(path: path, at: root) == snapshot {
                valid[path] = snapshot
            }
        }
        for (path, snapshot) in snapshots where original[path] != snapshot {
            valid[path] = snapshot
        }
        return valid
    }

    func replaceValidated(_ snapshots: [String: String]) {
        if self.snapshots != snapshots {
            self.snapshots = snapshots
        }
    }
}
