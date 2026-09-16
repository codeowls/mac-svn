import AppKit
import SwiftUI
import SVNCore

struct CheckoutProgress {
    let startedAt = Date()
    var lastOutputAt = Date()
    var completedItemCount = 0
    var lastCompletedPath: String?
    var isOpeningWorkingCopy = false
}

enum HistoryState {
    case idle
    case loading
    case loaded
    case failed(message: String, requiresAuthentication: Bool)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var workingCopy: WorkingCopy?
    @Published var entries: [StatusEntry] = []
    @Published var selectedPaths: Set<String> = []
    @Published var focusedPath: String?
    @Published var diffText = "选择一个文件查看差异"
    @Published var logs: [LogEntry] = []
    @Published var selectedHistoryRevision: String?
    @Published private(set) var historyState: HistoryState = .idle
    @Published var message = ""
    @Published var operation = ""
    @Published var result = "欢迎使用 Mac SVN"
    @Published var errorMessage: String?
    @Published var recentPaths: [String] = UserDefaults.standard.stringArray(forKey: "workingCopies") ?? []
    @Published private(set) var recentRepositoryURLs: [String] =
        UserDefaults.standard.stringArray(forKey: "recentRepositoryURLs") ?? []
    @Published var executablePath: String = UserDefaults.standard.string(forKey: "svnExecutable")
        ?? SVNClient.discoverExecutable()?.path ?? ""
    @Published private(set) var globalIgnores: String? = UserDefaults.standard.string(forKey: "svnGlobalIgnores")
    @Published var showIgnored = false
    @Published var showHistory = false
    @Published private(set) var checkoutProgress: CheckoutProgress?
    @Published private(set) var authenticationStore = SVNAuthenticationStore()
    @Published private(set) var isAuthenticating = false
    private var operationTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    var isBusy: Bool { !operation.isEmpty || isAuthenticating }
    var selectedEntries: [StatusEntry] { entries.filter { selectedPaths.contains($0.path) } }
    var canCommit: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy(\.canCommit)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canAdd: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.item == "unversioned" }
    }

    func client(for repository: String? = nil) throws -> SVNClient {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SVNError("未找到 SVN。请先运行 brew install subversion，并在设置中指定 svn 可执行文件。")
        }
        let authentication = (repository ?? workingCopy?.repositoryURL).flatMap {
            authenticationStore.authentication(for: $0)
        }
        return SVNClient(
            executable: URL(fileURLWithPath: executablePath),
            authentication: authentication,
            globalIgnores: globalIgnores
        )
    }

    /// 登录仅做远端读取验证，成功后按仓库根路径保存会话，不自动重试写操作。
    func authenticate(repository: String, username: String, password: String) async throws {
        guard !isBusy else {
            throw SVNError("请等待当前操作完成。")
        }
        guard let scheme = URLComponents(string: repository)?.scheme?.lowercased(),
              ["http", "https", "svn"].contains(scheme) else {
            throw SVNError("账号密码登录支持 http://、https:// 和 svn:// 地址。file:// 不需要登录，svn+ssh:// 使用系统 SSH 认证。")
        }
        let authentication = try SVNAuthentication(username: username, password: password)
        let executable = try client(for: repository).executable
        isAuthenticating = true
        defer { isAuthenticating = false }
        let client = SVNClient(executable: executable, authentication: authentication, globalIgnores: globalIgnores)
        let location = try await client.repositoryLocation(repository)
        try Task.checkCancellation()
        authenticationStore.set(authentication, for: location.rootURL)
        rememberRepository(location.url)
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
            let entries = try await client.status(at: copy.root, includeIgnored: self.showIgnored)
            self.diffTask?.cancel()
            self.workingCopy = copy
            self.entries = entries
            self.selectedPaths = []
            self.focusedPath = nil
            self.diffText = "选择一个文件查看差异"
            self.resetHistory()
            self.message = ""
            self.showHistory = false
            self.remember(copy.root)
            self.rememberRepository(copy.repositoryURL)
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
            let client = try self.client()
            // SVN 会添加被显式指定的忽略项目；界面旧选择不能绕过当前规则。
            let current = try await client.status(at: copy.root)
            for path in paths {
                guard current.contains(where: { $0.path == path && $0.item == "unversioned" }) else {
                    throw SVNError("\(path) 已被忽略或状态已变化，请刷新后重新选择。")
                }
            }
            self.result = try await client.add(paths: paths, at: copy.root)
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
            let client = try self.client(for: repository)
            self.checkoutProgress = CheckoutProgress()
            self.result = "正在连接仓库，检出到：\(destination.path)\n"
            // 先消费完输出再发布完成/失败，避免后台回调覆盖终态或下一次操作。
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let reader = Task { @MainActor in
                for await text in stream {
                    self.receiveCheckoutOutput(text)
                }
            }
            let output: String
            do {
                output = try await client.checkout(repository: repository, destination: destination) { text in
                    continuation.yield(text)
                }
                continuation.finish()
                await reader.value
            } catch {
                continuation.finish()
                await reader.value
                if error is CancellationError {
                    throw SVNError("检出已中断；已下载内容保留在目标目录：\(destination.path)\n\n\(self.result)")
                }
                throw error
            }
            self.checkoutProgress?.isOpeningWorkingCopy = true
            self.operation = "打开检出的工作副本"
            let copy = try await client.workingCopy(at: destination)
            let entries = try await client.status(at: copy.root)
            self.workingCopy = copy
            self.entries = entries
            self.selectedPaths = []
            self.focusedPath = nil
            self.diffText = "选择一个文件查看差异"
            self.resetHistory()
            self.message = ""
            self.showHistory = false
            self.remember(copy.root)
            self.rememberRepository(copy.repositoryURL)
            self.result = "检出完成，已打开：\(destination.path)\n\n\(self.formatCheckoutOutput(output))"
        }
    }

    /// SVN 的 A 通知表示文件或目录已完成检出，不将它误当作正在传输的文件或百分比。
    private func receiveCheckoutOutput(_ text: String) {
        result += formatCheckoutOutput(text)
        checkoutProgress?.lastOutputAt = Date()
        for line in text.split(separator: "\n") where line.hasPrefix("A    ") {
            checkoutProgress?.completedItemCount += 1
            checkoutProgress?.lastCompletedPath = String(line.dropFirst(5))
        }
    }

    /// 将检出的新增通知显示为中文，保留其他输出和换行，避免改写错误信息。
    private func formatCheckoutOutput(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("A    ") else {
                return line
            }
            return "已检出：\(line.dropFirst(5))"
        }.joined(separator: "\n")
    }

    /// 历史失败与空历史分开呈现；认证后只重试这一只读请求，不重放任何写操作。
    func loadHistory() {
        guard !isBusy, let copy = workingCopy else { return }
        showHistory = true
        resetHistory()
        historyState = .loading
        perform("读取最近 50 条历史", reportFailure: { error in
            let svnError = error as? SVNError
            let message = error is CancellationError ? "历史读取已取消，可重新加载。" : error.localizedDescription
            self.historyState = .failed(
                message: message,
                requiresAuthentication: svnError?.requiresAuthentication == true
            )
            self.result = svnError?.diagnostic ?? message
        }) {
            self.logs = try await self.client().history(at: copy.root)
            self.selectedHistoryRevision = self.logs.first?.revision
            self.historyState = .loaded
            self.result = "已读取 \(self.logs.count) 条历史记录"
        }
    }

    private func resetHistory() {
        logs = []
        selectedHistoryRevision = nil
        historyState = .idle
    }

    /// Cancel the previous request and check identity so old diff results never overwrite new selections.
    func loadDiff() {
        diffTask?.cancel()
        guard let path = focusedPath, let copy = workingCopy,
              let entry = entries.first(where: { $0.path == path }) else {
            diffText = "选择一个文件查看差异"
            return
        }
        if entry.item == "unversioned" {
            diffText = "此项目存在于本地，但尚未纳入 SVN 版本控制，没有可比较的仓库基准版本。\n\n需要提交时，先勾选并点击“添加到 SVN”；添加只安排版本控制，提交后才会上传。添加目录不会自动添加子文件。\n\n不需要提交的本地文件可以保留原状。"
            return
        }
        if entry.item == "ignored" {
            diffText = "此项目匹配 SVN 忽略规则，未纳入版本控制，不会列入添加或提交候选。\n\n规则可能来自本应用的全局忽略设置、系统 SVN 配置或目录忽略属性。需要添加时，请先调整对应规则并刷新。已受版本控制的文件不受忽略规则影响。"
            return
        }
        if ["external", "missing", "obstructed", "incomplete"].contains(entry.item) {
            diffText = "\(entry.label)：\(path)\n\n当前状态无法展示文本差异，请先检查工作副本；外部工作副本需单独打开。"
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

    /// 配置保存后统一用于所有新命令，并刷新状态以清除已经被忽略的旧选择。
    func saveSettings(executablePath: String, globalIgnores: String?) throws {
        guard !isBusy else {
            throw SVNError("请等待当前操作完成后再保存设置。")
        }
        let executable = try SVNConfiguration.executableURL(for: executablePath)
        let patterns = try globalIgnores.map(SVNConfiguration.normalizeIgnorePatterns)
        self.executablePath = executable.path
        self.globalIgnores = patterns
        UserDefaults.standard.set(executable.path, forKey: "svnExecutable")
        if let patterns {
            UserDefaults.standard.set(patterns, forKey: "svnGlobalIgnores")
        } else {
            UserDefaults.standard.removeObject(forKey: "svnGlobalIgnores")
        }
        selectedPaths = []
        if workingCopy != nil {
            refresh()
        }
    }

    func cancel() {
        operationTask?.cancel()
    }

    /// 移除记录时同步关闭对应工作区；磁盘文件保持不变。
    func removeRecentPath(_ path: String) {
        guard !isBusy else { return }
        recentPaths.removeAll { $0 == path }
        UserDefaults.standard.set(recentPaths, forKey: "workingCopies")
        if workingCopy?.root.path == path || recentPaths.isEmpty {
            closeWorkingCopy()
        }
    }

    /// 清空副本相关状态，并阻止尚未完成的差异请求重新填充界面。
    private func closeWorkingCopy() {
        diffTask?.cancel()
        diffTask = nil
        workingCopy = nil
        entries = []
        selectedPaths = []
        focusedPath = nil
        diffText = "选择一个文件查看差异"
        resetHistory()
        message = ""
        showHistory = false
        errorMessage = nil
        result = "欢迎使用 Mac SVN"
    }

    /// 记录成功访问的仓库地址，最近使用的排在前面；与登录密码分开持久化。
    func rememberRepository(_ repository: String) {
        guard let url = URLComponents(string: repository), url.password == nil else {
            return
        }
        recentRepositoryURLs = [repository] + recentRepositoryURLs.filter { $0 != repository }
        recentRepositoryURLs = Array(recentRepositoryURLs.prefix(12))
        UserDefaults.standard.set(recentRepositoryURLs, forKey: "recentRepositoryURLs")
    }

    /// 已有副本保持位置，避免侧栏点击后换位；仅新副本加入顶部。
    private func remember(_ root: URL) {
        guard !recentPaths.contains(root.path) else { return }
        recentPaths.insert(root.path, at: 0)
        recentPaths = Array(recentPaths.prefix(12))
        UserDefaults.standard.set(recentPaths, forKey: "workingCopies")
    }

    private func reload() async throws {
        guard let copy = workingCopy else { return }
        let client = try client()
        let newEntries = try await client.status(at: copy.root, includeIgnored: showIgnored)
        let newInfo = try await client.workingCopy(at: copy.root)
        entries = newEntries
        workingCopy = newInfo
        selectedPaths.formIntersection(Set(entries.filter { $0.canCommit || $0.item == "unversioned" }.map(\.path)))
        resetHistory()
        loadDiff()
    }

    /// One foreground operation at a time; an interrupted write is followed by a fresh status read.
    private func perform(
        _ title: String,
        refreshAfterFailure: Bool = false,
        reportFailure: ((Error) -> Void)? = nil,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        diffTask?.cancel()
        operation = title
        operationTask = Task {
            defer {
                checkoutProgress = nil
                operation = ""
                operationTask = nil
            }
            do {
                try await action()
            } catch {
                if let reportFailure {
                    reportFailure(error)
                    return
                }
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
