import Foundation

/// 只观察当前副本；合并文件事件，并让前台操作优先使用 SVN。
@MainActor
final class WorkspaceRefreshController {
    private let refresh: @MainActor (URL) async throws -> Void
    private let reportFailure: @MainActor (Error) -> Void
    private var root: URL?
    private var watcher: FinderBadgeWatcher?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pending = false
    private var suspended = false
    private(set) var observationError: Error?

    init(
        refresh: @escaping @MainActor (URL) async throws -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.refresh = refresh
        self.reportFailure = reportFailure
    }

    func watch(_ root: URL) {
        guard self.root != root else { return }
        stop()
        self.root = root
        do {
            watcher = try FinderBadgeWatcher(root: root.path) { [weak self] in
                self?.request()
            }
        } catch {
            observationError = error
            reportFailure(error)
        }
    }

    func request() {
        guard root != nil else { return }
        pending = true
        schedule()
    }

    /// 调用方等待已取消的读取结束后再执行写操作，避免争用工作副本。
    func suspend() -> Task<Void, Never>? {
        suspended = true
        if task != nil { pending = true }
        task?.cancel()
        return task
    }

    func resume() {
        suspended = false
        schedule()
    }

    func stop() {
        generation = UUID()
        watcher?.stop()
        watcher = nil
        task?.cancel()
        task = nil
        root = nil
        pending = false
        observationError = nil
    }

    private func schedule() {
        guard pending, !suspended, task == nil, let root else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                self.pending = false
                try await self.refresh(root)
            } catch is CancellationError {
                // 切换副本或启动前台操作时，取消的旧结果不能覆盖当前工作区。
            } catch {
                if !Task.isCancelled, self.generation == generation {
                    self.reportFailure(error)
                }
            }
            guard self.generation == generation else { return }
            self.task = nil
            self.schedule()
        }
    }
}
