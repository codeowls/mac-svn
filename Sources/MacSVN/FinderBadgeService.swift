import Foundation
import OSLog
import SVNCore

/// 主应用统一扫描；多个访达／文件选择器扩展实例共用同一个副本状态快照。
@MainActor
final class FinderBadgeService: NSObject, ObservableObject {
    static let shared = FinderBadgeService()
    @Published private(set) var errors: [String: String] = [:]
    private let logger = Logger(subsystem: "io.github.codeowls.mac-svn", category: "FinderBadges")
    private var roots = Set<String>()
    private var executable = ""
    private var globalIgnores: String?
    private var watchers: [String: FinderBadgeWatcher] = [:]
    private var snapshots: [String: FinderBadgeSnapshot] = [:]
    private var pending: [String: [FinderBadgeRequest]] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    private override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receiveRequest(_:)), name: FinderBadgeRequest.notification, object: nil
        )
    }

    func configure(roots: [String], executable: String, globalIgnores: String?) {
        let selected = Set(roots)
        guard selected != self.roots || executable != self.executable || globalIgnores != self.globalIgnores else { return }
        stop()
        self.roots = selected
        self.executable = executable
        self.globalIgnores = globalIgnores
        for root in selected {
            do {
                watchers[root] = try FinderBadgeWatcher(root: root) { [weak self] in self?.invalidate(root) }
            } catch {
                report(error, root: root)
            }
        }
    }

    /// 配置停用或退出应用时撤销快照，扩展保留菜单但不继续展示过期角标。
    func stop() {
        for root in roots { notifyInvalidation(root) }
        for watcher in watchers.values { watcher.stop() }
        for task in tasks.values { task.cancel() }
        watchers.removeAll()
        tasks.removeAll()
        generations.removeAll()
        snapshots.removeAll()
        pending.removeAll()
        errors.removeAll()
        roots.removeAll()
    }

    func invalidate(_ root: String) {
        guard roots.contains(root) else { return }
        snapshots.removeValue(forKey: root)
        generations[root] = UUID()
        tasks.removeValue(forKey: root)?.cancel()
        notifyInvalidation(root)
        if pending[root]?.isEmpty == false { scan(root, delay: true) }
    }

    @objc private func receiveRequest(_ notification: Notification) {
        guard let value = notification.object as? String else { return }
        do {
            let request = try FinderBadgeRequest.decode(value)
            guard roots.contains(request.root) else { return }
            if let snapshot = snapshots[request.root], Date().timeIntervalSince(snapshot.scannedAt) < 10 {
                respond(request, snapshot: snapshot)
                return
            }
            pending[request.root, default: []].append(request)
            if tasks[request.root] == nil { scan(request.root, delay: false) }
        } catch {
            logger.error("Rejected badge request: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scan(_ root: String, delay: Bool) {
        let generation = generations[root] ?? UUID()
        generations[root] = generation
        let client = SVNClient(executable: URL(fileURLWithPath: executable), globalIgnores: globalIgnores)
        tasks[root] = Task { [weak self] in
            do {
                if delay { try await Task.sleep(for: .milliseconds(500)) }
                // 解析和状态汇总也离开主线程，避免大副本阻塞主窗口。
                let scan = Task.detached {
                    try await client.finderBadgeSnapshot(at: URL(fileURLWithPath: root))
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.generations[root] == generation, self.roots.contains(root) else { return }
                self.snapshots[root] = snapshot
                // 事件流建立失败的错误继续保留；状态扫描成功不能代替事件观察成功。
                if self.watchers[root] != nil { self.errors.removeValue(forKey: root) }
                self.finish(root, snapshot: snapshot)
            } catch {
                guard let self, self.generations[root] == generation, self.roots.contains(root) else { return }
                self.snapshots.removeValue(forKey: root)
                self.report(error, root: root)
                self.finish(root, snapshot: nil)
            }
        }
    }

    private func finish(_ root: String, snapshot: FinderBadgeSnapshot?) {
        tasks.removeValue(forKey: root)
        let requests = pending.removeValue(forKey: root) ?? []
        for request in requests { respond(request, snapshot: snapshot) }
    }

    private func respond(_ request: FinderBadgeRequest, snapshot: FinderBadgeSnapshot?) {
        let paths = Set(request.paths)
        let badges = snapshot?.badges.filter { paths.contains($0.key) } ?? [:]
        let response = FinderBadgeResponse(request: request, scannedAt: snapshot?.scannedAt ?? Date(), badges: badges)
        do {
            DistributedNotificationCenter.default().postNotificationName(
                FinderBadgeResponse.notification, object: try response.encoded(), userInfo: nil, deliverImmediately: true
            )
        } catch {
            report(error, root: request.root)
        }
    }

    private func notifyInvalidation(_ root: String) {
        DistributedNotificationCenter.default().postNotificationName(
            FinderBadgeResponse.invalidated, object: root, userInfo: nil, deliverImmediately: true
        )
    }

    private func report(_ error: Error, root: String) {
        errors[root] = error.localizedDescription
        logger.error("Badge scan failed for \(root, privacy: .private): \(error.localizedDescription, privacy: .public)")
    }
}
