import AppKit
import SwiftUI
import SVNCore

@MainActor
final class AppModel: ObservableObject {
    @Published var workingCopy: WorkingCopy?
    @Published var entries: [StatusEntry] = []
    @Published var selectedPaths: Set<String> = []
    @Published var focusedPath: String?
    @Published var diffText = "选择一个文件查看差异"
    @Published var logs: [LogEntry] = []
    @Published var message = ""
    @Published var operation = ""
    @Published var result = "欢迎使用 Mac SVN"
    @Published var errorMessage: String?
    @Published var recentPaths: [String] = UserDefaults.standard.stringArray(forKey: "workingCopies") ?? []
    @Published var executablePath: String = UserDefaults.standard.string(forKey: "svnExecutable")
        ?? SVNClient.discoverExecutable()?.path ?? ""
    @Published var showHistory = false
    private var operationTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    var isBusy: Bool { !operation.isEmpty }
    var selectedEntries: [StatusEntry] { entries.filter { selectedPaths.contains($0.path) } }
    var canCommit: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy(\.canCommit)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canAdd: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.item == "unversioned" }
    }

    func client() throws -> SVNClient {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SVNError("未找到 SVN。请先运行 brew install subversion，并在设置中指定 svn 可执行文件。")
        }
        return SVNClient(executable: URL(fileURLWithPath: executablePath))
    }

    func chooseWorkingCopy() {
        let panel = NSOpenPanel()
        panel.title = "打开 SVN 工作副本"
        panel.prompt = "打开"
        panel.message = "选择已经检出的本地工作副本。远端仓库请使用“检出远端”。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ directory: URL) {
        perform("读取工作副本") {
            let client = try self.client()
            let copy = try await client.workingCopy(at: directory)
            let entries = try await client.status(at: copy.root)
            self.diffTask?.cancel()
            self.workingCopy = copy
            self.entries = entries
            self.selectedPaths = []
            self.focusedPath = nil
            self.diffText = "选择一个文件查看差异"
            self.logs = []
            self.message = ""
            self.showHistory = false
            self.remember(copy.root)
            self.result = "已打开 \(copy.root.lastPathComponent)，\(entries.count) 项状态记录"
        }
    }

    func refresh() {
        perform("刷新本地状态") {
            try await self.reload()
            self.result = "本地状态已刷新"
        }
    }

    func update() {
        guard let copy = workingCopy else { return }
        perform("更新工作副本", refreshAfterFailure: true) {
            self.result = try await self.client().update(at: copy.root)
            try await self.reload()
            if self.entries.contains(where: \.isConflict) {
                self.result += "\n更新产生冲突，请检查标记为冲突的文件。首版请使用外部工具解决冲突。"
            }
        }
    }

    func addSelected() {
        guard let copy = workingCopy, canAdd else { return }
        let paths = selectedPaths.sorted()
        perform("添加选中项目", refreshAfterFailure: true) {
            self.result = try await self.client().add(paths: paths, at: copy.root)
            try await self.reload()
        }
    }

    func commitSelected() {
        guard let copy = workingCopy, canCommit else { return }
        let paths = selectedPaths.sorted()
        let commitMessage = message
        perform("提交选中项目", refreshAfterFailure: true) {
            self.result = try await self.client().commit(paths: paths, message: commitMessage, at: copy.root)
            self.message = ""
            self.selectedPaths = []
            do {
                try await self.reload()
            } catch {
                throw SVNError("提交已成功，但重新读取工作副本失败，请勿重复提交。\n\n\(error.localizedDescription)")
            }
        }
    }

    func checkout(repository: String, destination: URL) {
        perform("检出仓库") {
            let client = try self.client()
            self.result = try await client.checkout(repository: repository, destination: destination)
            let copy = try await client.workingCopy(at: destination)
            let entries = try await client.status(at: copy.root)
            self.workingCopy = copy
            self.entries = entries
            self.selectedPaths = []
            self.focusedPath = nil
            self.diffText = "选择一个文件查看差异"
            self.logs = []
            self.message = ""
            self.showHistory = false
            self.remember(copy.root)
        }
    }

    func loadHistory() {
        guard let copy = workingCopy else { return }
        showHistory = true
        perform("读取最近 50 条历史") {
            self.logs = try await self.client().history(at: copy.root)
            self.result = "已读取 \(self.logs.count) 条历史记录"
        }
    }

    /// Cancel the previous request and check identity so old diff results never overwrite new selections.
    func loadDiff() {
        diffTask?.cancel()
        guard let path = focusedPath, let copy = workingCopy,
              let entry = entries.first(where: { $0.path == path }) else {
            diffText = "选择一个文件查看差异"
            return
        }
        if ["unversioned", "external", "missing", "obstructed", "incomplete"].contains(entry.item) {
            diffText = "\(entry.label)：\(path)\n\n未跟踪文件请先添加，再查看 SVN 差异。缺失或冲突项目请先检查工作副本。"
            return
        }
        diffText = "正在读取差异…"
        diffTask = Task {
            do {
                let text = try await client().diff(path: path, at: copy.root)
                guard !Task.isCancelled, focusedPath == path, workingCopy?.root == copy.root else { return }
                diffText = text
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                diffText = error.localizedDescription
            }
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(executablePath, forKey: "svnExecutable")
    }

    func cancel() {
        operationTask?.cancel()
    }

    /// 仅移除最近记录，保留磁盘文件及当前已打开的工作副本。
    func removeRecentPath(_ path: String) {
        recentPaths.removeAll { $0 == path }
        UserDefaults.standard.set(recentPaths, forKey: "workingCopies")
    }

    private func remember(_ root: URL) {
        recentPaths = [root.path] + recentPaths.filter { $0 != root.path }
        recentPaths = Array(recentPaths.prefix(12))
        UserDefaults.standard.set(recentPaths, forKey: "workingCopies")
    }

    private func reload() async throws {
        guard let copy = workingCopy else { return }
        let client = try client()
        let newEntries = try await client.status(at: copy.root)
        let newInfo = try await client.workingCopy(at: copy.root)
        entries = newEntries
        workingCopy = newInfo
        selectedPaths.formIntersection(Set(entries.map(\.path)))
        logs = []
        loadDiff()
    }

    /// One foreground operation at a time; an interrupted write is followed by a fresh status read.
    private func perform(
        _ title: String,
        refreshAfterFailure: Bool = false,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        diffTask?.cancel()
        operation = title
        operationTask = Task {
            defer {
                operation = ""
                operationTask = nil
            }
            do {
                try await action()
            } catch {
                var detail = error is CancellationError
                    ? "操作已中断；已产生的本地变更不会自动撤销。请刷新状态后检查。"
                    : error.localizedDescription
                if refreshAfterFailure {
                    // A new task is needed because the interrupted operation's task is cancelled.
                    let refresh = Task { @MainActor in try await self.reload() }
                    do {
                        try await refresh.value
                    } catch {
                        detail += "\n\n重新读取状态失败：\(error.localizedDescription)"
                    }
                }
                errorMessage = detail
                result = detail
            }
        }
    }
}
