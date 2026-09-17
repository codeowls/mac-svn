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

struct CheckoutRecovery {
    let destination: URL
    var inspection: CheckoutInspection?
    var error: String?
}

enum HistoryState {
    case idle
    case loading
    case loaded
    case failed(message: String, requiresAuthentication: Bool)
}

struct WriteOperationProgress {
    enum Phase: String {
        case running = "进行中"
        case completed = "完成"
        case failed = "失败"
        case cancelled = "已取消"
        case completedWithWarning = "操作已完成，状态刷新未完成"
    }

    let id = UUID()
    let title: String
    let startedAt = Date()
    var lastOutputAt = Date()
    var finishedAt: Date?
    var phase: Phase = .running
}

struct DirectoryIgnoreDraft: Identifiable {
    var id: UUID { settings.id }
    let settings: DirectoryIgnoreSettings
    let initialPatterns: String
}

private struct WorkingCopyDraftKey: Hashable {
    let path: String
    let repository: String

    init(_ copy: WorkingCopy) {
        path = copy.root.resolvingSymlinksInPath().path
        repository = copy.repositoryURL
    }
}

private struct WorkingCopyDraft {
    var message = ""
    var fileFilter = ""
    var selectedPaths: Set<String> = []
    var showIgnored = false
    var historyFilter = HistoryFilter()
    var historyPath = "."
}

@MainActor
final class AppModel: ObservableObject {
    weak var mainWindow: NSWindow?
    @Published var workingCopy: WorkingCopy?
    @Published var entries: [StatusEntry] = []
    @Published var selectedPaths: Set<String> = []
    @Published var focusedPath: String?
    @Published var diffText = "选择一个文件查看差异"
    @Published var logs: [LogEntry] = []
    @Published var selectedHistoryRevision: String?
    @Published private(set) var historyState: HistoryState = .idle
    @Published private(set) var historyPath = "."
    @Published var historyFilter = HistoryFilter()
    @Published private(set) var nextHistoryRevision: Int?
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var historyPageError: String?
    @Published private(set) var historyPageRequiresAuthentication = false
    @Published var message = ""
    @Published var fileFilter = ""
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
    @Published var checkoutRecovery: CheckoutRecovery?
    @Published private(set) var writeProgress: WriteOperationProgress?
    @Published var revertPlan: RevertPlan?
    @Published var directoryIgnoreDraft: DirectoryIgnoreDraft?
    @Published var directoryIgnoreError: String?
    @Published var conflictDetails: ConflictDetails?
    @Published var conflictResolutionPlan: ConflictResolutionPlan?
    @Published var conflictError: String?
    @Published private(set) var authenticationStore = SVNAuthenticationStore()
    @Published private(set) var isAuthenticating = false
    private var operationTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var workingCopyDrafts: [WorkingCopyDraftKey: WorkingCopyDraft] = [:]

    var isBusy: Bool { !operation.isEmpty || isAuthenticating }
    var selectedEntries: [StatusEntry] { entries.filter { selectedPaths.contains($0.path) } }
    var filteredLogs: [LogEntry] { logs.filter(historyFilter.matches) }
    var canCommit: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy(\.canCommit)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canAdd: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.item == "unversioned" }
    }
    var canRevert: Bool {
        !isBusy && !selectedEntries.isEmpty && selectedEntries.allSatisfy(\.canRevert)
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
        guard let window = mainWindow else {
            errorMessage = "未能定位主窗口，请重新打开应用后再选择工作副本。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "打开 SVN 工作副本"
        panel.prompt = "打开"
        panel.message = "选择已经检出的本地工作副本。远端仓库请使用“检出远端”。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.open(url)
        }
    }

    func open(_ directory: URL) {
        perform("读取工作副本") {
            let copy = try await self.readWorkingCopy(at: directory)
            self.result = "已打开 \(copy.root.lastPathComponent)，\(self.entries.count) 项状态记录"
        }
    }

    /// 副本切换及右键操作共用同一读取流程，成功读取后才替换当前工作区。
    private func readWorkingCopy(at directory: URL) async throws -> WorkingCopy {
        let client = try client()
        let discovered = try await client.workingCopy(at: directory)
        let copy = directory.resolvingSymlinksInPath() == discovered.root.resolvingSymlinksInPath()
            ? discovered : try await client.workingCopy(at: discovered.root)
        let key = WorkingCopyDraftKey(copy)
        let draft = workingCopy.map(WorkingCopyDraftKey.init) == key
            ? currentDraft() : workingCopyDrafts[key] ?? WorkingCopyDraft()
        let entries = try await client.status(at: copy.root, includeIgnored: draft.showIgnored)
        try Task.checkCancellation()
        // 成功读取目标后才保存并切换，打开失败或取消不会丢失当前副本的编辑内容。
        if let previous = workingCopy {
            workingCopyDrafts[WorkingCopyDraftKey(previous)] = currentDraft()
        }
        diffTask?.cancel()
        workingCopy = copy
        self.entries = entries
        selectedPaths = draft.selectedPaths.intersection(selectablePaths(in: entries))
        fileFilter = draft.fileFilter
        showIgnored = draft.showIgnored
        focusedPath = nil
        diffText = "选择一个文件查看差异"
        resetHistory()
        historyFilter = draft.historyFilter
        historyPath = draft.historyPath
        message = draft.message
        showHistory = false
        revertPlan = nil
        directoryIgnoreDraft = nil
        directoryIgnoreError = nil
        conflictDetails = nil
        conflictResolutionPlan = nil
        conflictError = nil
        remember(copy.root)
        rememberRepository(copy.repositoryURL)
        return copy
    }

    /// 草稿只留在当前 App 会话，按本地根目录及仓库 URL 隔离，不持久化提交内容。
    private func currentDraft() -> WorkingCopyDraft {
        WorkingCopyDraft(
            message: message, fileFilter: fileFilter, selectedPaths: selectedPaths,
            showIgnored: showIgnored, historyFilter: historyFilter, historyPath: historyPath
        )
    }

    private func selectablePaths(in entries: [StatusEntry]) -> Set<String> {
        Set(entries.filter { $0.canCommit || $0.canRevert || $0.item == "unversioned" }.map(\.path))
    }

    func refresh(at directory: URL? = nil) {
        guard let directory = directory ?? workingCopy?.root else { return }
        perform("刷新本地状态") {
            if self.workingCopy?.root == directory {
                try await self.reload()
            } else {
                _ = try await self.readWorkingCopy(at: directory)
            }
            self.result = "本地状态已刷新"
        }
    }

    func update(at directory: URL? = nil) {
        guard let directory = directory ?? workingCopy?.root else { return }
        perform("更新工作副本", refreshAfterFailure: true, streamOutput: true) {
            let copy: WorkingCopy
            if let current = self.workingCopy, current.root == directory {
                copy = current
            } else {
                copy = try await self.readWorkingCopy(at: directory)
            }
            let client = try self.client(for: copy.repositoryURL)
            try await self.receiveLiveOutput { onOutput in
                try await client.update(at: copy.root, onOutput: onOutput)
            }
            self.writeProgress?.phase = .completed
            try await self.reload()
            if self.entries.contains(where: \.isConflict) {
                self.result += "\n更新产生冲突，请点击冲突项目查看详情；处理最终内容后再检查并标记解决。"
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
        perform(
            "提交选中项目", refreshAfterFailure: true, streamOutput: true,
            cancellationMessage: "提交已取消；服务器结果未确认，请先查看仓库历史核实，勿直接重复提交。"
        ) {
            let client = try self.client()
            try await self.receiveLiveOutput { onOutput in
                try await client.commit(paths: paths, message: commitMessage, at: copy.root, onOutput: onOutput)
            }
            self.writeProgress?.phase = .completed
            self.message = ""
            self.selectedPaths = []
            do {
                try await self.reload()
            } catch {
                throw SVNError("提交已成功，但重新读取工作副本失败，请勿重复提交。\n\n\(error.localizedDescription)")
            }
        }
    }

    /// 在弹出确认窗口前读取实际状态和差异；确认清单绑定当前副本及内容快照。
    func prepareRevert(paths: [String]? = nil) {
        guard !isBusy, let copy = workingCopy else { return }
        let paths = paths ?? selectedPaths.sorted()
        perform("检查还原范围") {
            let plan = try await self.client().prepareRevert(paths: paths, at: copy.root)
            try Task.checkCancellation()
            self.revertPlan = plan
            self.result = "请检查 \(plan.items.count) 项还原内容，确认前不会修改文件。"
        }
    }

    func confirmRevert(_ plan: RevertPlan) {
        guard !isBusy, workingCopy?.root == plan.root, revertPlan?.id == plan.id else { return }
        revertPlan = nil
        perform("还原选中项目", refreshAfterFailure: true) {
            self.result = try await self.client().revert(plan)
            try await self.reload()
            self.result = "还原完成\n\n" + self.result
        }
    }

    func inspectConflict(path: String) {
        guard !isBusy, let copy = workingCopy else { return }
        conflictError = nil
        conflictResolutionPlan = nil
        perform("读取冲突详情", reportFailure: { error in
            if self.conflictDetails != nil {
                self.conflictError = error.localizedDescription
            } else {
                self.errorMessage = error.localizedDescription
            }
        }) {
            self.conflictDetails = try await self.client().conflictDetails(path: path, at: copy.root)
        }
    }

    func prepareConflictResolution(_ details: ConflictDetails) {
        guard !isBusy, conflictDetails?.id == details.id else { return }
        conflictError = nil
        perform("检查解决结果", reportFailure: { error in
            self.conflictError = error.localizedDescription
        }) {
            self.conflictResolutionPlan = try await self.client().prepareConflictResolution(details)
        }
    }

    /// 用户确认最终内容后才解除冲突；失败或取消仍重新读取状态，不自动重新提交。
    func confirmConflictResolution(_ plan: ConflictResolutionPlan) {
        guard !isBusy, conflictResolutionPlan?.id == plan.id,
              conflictDetails?.id == plan.details.id, workingCopy?.root == plan.details.root else { return }
        conflictResolutionPlan = nil
        conflictDetails = nil
        perform("标记冲突已解决", refreshAfterFailure: true) {
            self.result = try await self.client().resolveConflict(plan)
            do {
                try await self.reload()
            } catch {
                throw SVNError("该文件已标记解决，但工作区刷新失败，请重新刷新检查。\n\(error.localizedDescription)")
            }
        }
    }

    /// 查看已有规则与快捷添加共用编辑窗口，用户保存前不改变 SVN 属性。
    func editDirectoryIgnores(path: String = ".", adding pattern: String? = nil) {
        guard let copy = workingCopy else { return }
        perform("读取目录忽略规则") {
            let settings = try await self.client().directoryIgnores(path: path, at: copy.root)
            try Task.checkCancellation()
            var text = settings.patterns ?? ""
            if let pattern, !text.components(separatedBy: "\n").contains(pattern) {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += pattern + "\n"
            }
            self.directoryIgnoreError = nil
            self.directoryIgnoreDraft = DirectoryIgnoreDraft(settings: settings, initialPatterns: text)
            self.result = "已读取目录忽略规则，保存前不会修改属性。"
        }
    }

    func ignoreUnversioned(_ entry: StatusEntry, byExtension: Bool = false) {
        guard !isBusy, entry.item == "unversioned" else { return }
        do {
            let name = (entry.path as NSString).lastPathComponent
            let suffix = (name as NSString).pathExtension
            guard !byExtension || !suffix.isEmpty else { throw SVNError("该项目没有可忽略的扩展名。") }
            let pattern = byExtension
                ? "*." + (try SVNConfiguration.literalIgnorePattern(suffix))
                : try SVNConfiguration.literalIgnorePattern(name)
            editDirectoryIgnores(path: parentDirectory(of: entry.path), adding: pattern)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    func isLocalDirectory(_ path: String) -> Bool {
        guard let copy = workingCopy else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: copy.root.appendingPathComponent(path).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func chooseDirectoryIgnores() {
        guard !isBusy, let copy = workingCopy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择目录编辑忽略规则"
        panel.prompt = "编辑忽略"
        panel.directoryURL = copy.root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = copy.root.resolvingSymlinksInPath().path
        let selected = url.resolvingSymlinksInPath().path
        guard selected == root || selected.hasPrefix(root + "/") else {
            errorMessage = "请选择当前工作副本内的受控目录。"
            return
        }
        editDirectoryIgnores(path: selected == root ? "." : String(selected.dropFirst(root.count + 1)))
    }

    func saveDirectoryIgnores(_ draft: DirectoryIgnoreDraft, patterns: String) {
        guard !isBusy, directoryIgnoreDraft?.id == draft.id, workingCopy?.root == draft.settings.root else { return }
        directoryIgnoreError = nil
        perform("保存目录忽略规则", reportFailure: { error in
            let detail = error is CancellationError
                ? "保存已取消；已经写入的属性不会回滚，请关闭后刷新检查。" : error.localizedDescription
            if self.directoryIgnoreDraft != nil {
                self.directoryIgnoreError = detail
            } else {
                self.errorMessage = detail
            }
            self.result = detail
        }) {
            self.result = try await self.client().saveDirectoryIgnores(draft.settings, patterns: patterns)
            self.directoryIgnoreDraft = nil
            do {
                try await self.reload()
            } catch {
                throw SVNError("目录忽略已保存，但刷新状态失败，请重新刷新检查。\n\(error.localizedDescription)")
            }
        }
    }

    /// 命令结束前持续消费双管道输出；发布终态前先排空日志，避免旧输出覆盖下一次操作。
    private func receiveLiveOutput(
        _ action: (@escaping @Sendable (String) -> Void) async throws -> String
    ) async throws {
        let output = CommandOutputStream()
        let reader = Task { @MainActor in
            for await text in output.stream {
                self.result += text
                self.writeProgress?.lastOutputAt = Date()
            }
        }
        do {
            _ = try await action { output.append($0) }
            output.finish()
            await reader.value
        } catch {
            output.finish()
            await reader.value
            throw error
        }
    }

    func checkout(repository: String, destination: URL) {
        perform(
            "检出仓库", streamOutput: true,
            cancellationMessage: "检出已中断，已下载内容保留在：\(destination.path)。请检查目标目录后决定如何继续。"
        ) {
            let client = try self.client(for: repository)
            self.checkoutRecovery = nil
            self.checkoutProgress = CheckoutProgress()
            self.result = "正在连接仓库，检出到：\(destination.path)\n"
            // 先消费完输出再发布完成/失败，避免后台回调覆盖终态或下一次操作。
            let stream = CommandOutputStream()
            let reader = Task { @MainActor in
                for await text in stream.stream {
                    self.receiveCheckoutOutput(text)
                }
            }
            let output: String
            do {
                output = try await client.checkout(repository: repository, destination: destination) { text in
                    stream.append(text)
                }
                stream.finish()
                await reader.value
            } catch {
                stream.finish()
                await reader.value
                // 取消的任务不能继续启动 SVN；独立只读检查完成后再发布原操作终态。
                let inspection = Task { @MainActor in
                    await self.inspectCheckout(destination: destination, client: client)
                }
                await inspection.value
                throw error
            }
            self.checkoutProgress?.isOpeningWorkingCopy = true
            self.operation = "打开检出的工作副本"
            self.writeProgress?.phase = .completed
            self.writeProgress?.finishedAt = Date()
            do {
                // 与打开副本共用草稿保存流程，检出新副本不会丢弃旧副本的提交说明和选择。
                _ = try await self.readWorkingCopy(at: destination)
            } catch {
                let inspection = Task { @MainActor in
                    await self.inspectCheckout(destination: destination, client: client)
                }
                await inspection.value
                throw SVNError("下载已完成，但打开工作副本失败，请检查目录后重新打开。\n\(error.localizedDescription)")
            }
            self.result = "检出完成，已打开：\(destination.path)\n\n\(self.formatCheckoutOutput(output))"
        }
    }

    /// 保留检出错误及输出；目录检查失败单独展示，不将失败伪装为可恢复的工作副本。
    private func inspectCheckout(destination: URL, client: SVNClient) async {
        checkoutRecovery = CheckoutRecovery(destination: destination)
        do {
            let inspection = try await client.inspectCheckout(at: destination)
            checkoutRecovery?.inspection = inspection
            result += "\n目录检查：\(inspection.summary)\n\(inspection.guidance)\n"
        } catch {
            checkoutRecovery?.error = error.localizedDescription
            result += "\n目录检查失败：\(error.localizedDescription)\n"
        }
    }

    func recheckCheckout() {
        guard let recovery = checkoutRecovery else { return }
        perform("检查检出目录") {
            await self.inspectCheckout(destination: recovery.destination, client: try self.client())
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

    /// 新的历史入口重置目标与筛选；重新加载及认证重试保留当前查询范围。
    func loadHistory(path: String = ".") {
        guard !isBusy, workingCopy != nil else { return }
        showHistory = true
        resetHistory()
        historyPath = path
        reloadHistory()
    }

    /// 标签切换沿用此副本的查询范围与筛选，显式选择其他路径仍重置历史查询。
    func showSavedHistory() {
        guard !isBusy, workingCopy != nil else { return }
        showHistory = true
        reloadHistory()
    }

    func reloadHistory() {
        guard !isBusy, workingCopy != nil else { return }
        readHistoryPage(append: false)
    }

    func loadMoreHistory() {
        guard !isBusy, workingCopy != nil, nextHistoryRevision != nil else { return }
        readHistoryPage(append: true)
    }

    func retryHistory() {
        if historyPageError != nil {
            loadMoreHistory()
        } else {
            reloadHistory()
        }
    }

    /// 每页成功后才替换列表和游标；续读失败或取消仍可浏览已读取的历史。
    private func readHistoryPage(append: Bool) {
        guard let copy = workingCopy else { return }
        let path = historyPath
        let cursor = append ? nextHistoryRevision : nil
        let previousSelection = selectedHistoryRevision
        if !append {
            historyState = .loading
        }
        isLoadingMoreHistory = append
        historyPageError = nil
        historyPageRequiresAuthentication = false
        perform(append ? "读取更早历史" : "读取最近 50 条历史", reportFailure: { error in
            self.isLoadingMoreHistory = false
            let svnError = error as? SVNError
            let message = error is CancellationError ? "历史读取已取消，可重新加载。" : error.localizedDescription
            if append {
                self.historyPageError = message
                self.historyPageRequiresAuthentication = svnError?.requiresAuthentication == true
            } else {
                self.historyState = .failed(
                    message: message,
                    requiresAuthentication: svnError?.requiresAuthentication == true
                )
            }
            self.result = svnError?.diagnostic ?? message
        }) {
            let page = try await self.client(for: copy.repositoryURL).historyPage(
                at: copy.root, path: path, beforeRevision: cursor
            )
            try Task.checkCancellation()
            guard self.workingCopy?.root == copy.root, self.historyPath == path else { return }
            self.logs = append ? self.logs + page.entries : page.entries
            self.nextHistoryRevision = page.nextBeforeRevision
            if !append {
                self.selectedHistoryRevision = previousSelection
            }
            self.reconcileHistorySelection()
            self.historyState = .loaded
            self.isLoadingMoreHistory = false
            self.result = "已读取 \(self.logs.count) 条历史记录"
        }
    }

    /// 筛选后同步右侧详情，避免继续展示已经隐藏的提交。
    func reconcileHistorySelection() {
        let visible = filteredLogs
        if !visible.contains(where: { $0.revision == selectedHistoryRevision }) {
            selectedHistoryRevision = visible.first?.revision
        }
    }

    /// 从文件选择器读取干净文件的历史，查询目标必须位于当前工作副本内。
    func chooseFileHistory() {
        guard !isBusy, let copy = workingCopy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择文件查看历史"
        panel.prompt = "查看历史"
        panel.message = "选择当前工作副本内已提交的文件；历史查询不会修改本地内容。"
        panel.directoryURL = copy.root
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = copy.root.resolvingSymlinksInPath().path + "/"
        let file = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        guard file.hasPrefix(root) else {
            errorMessage = "请选择当前工作副本内的文件。"
            return
        }
        loadHistory(path: String(file.dropFirst(root.count)))
    }

    private func resetHistory() {
        logs = []
        selectedHistoryRevision = nil
        historyState = .idle
        historyPath = "."
        historyFilter = HistoryFilter()
        nextHistoryRevision = nil
        isLoadingMoreHistory = false
        historyPageError = nil
        historyPageRequiresAuthentication = false
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
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        workingCopyDrafts = workingCopyDrafts.filter { $0.key.path != root }
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
        fileFilter = ""
        showIgnored = false
        showHistory = false
        errorMessage = nil
        revertPlan = nil
        directoryIgnoreDraft = nil
        directoryIgnoreError = nil
        conflictDetails = nil
        conflictResolutionPlan = nil
        conflictError = nil
        writeProgress = nil
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
        selectedPaths.formIntersection(selectablePaths(in: entries))
        let filter = historyFilter
        let path = historyPath
        resetHistory()
        historyFilter = filter
        historyPath = path
        loadDiff()
    }

    /// One foreground operation at a time; an interrupted write is followed by a fresh status read.
    private func perform(
        _ title: String,
        refreshAfterFailure: Bool = false,
        streamOutput: Bool = false,
        cancellationMessage: String? = nil,
        reportFailure: ((Error) -> Void)? = nil,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        diffTask?.cancel()
        operation = title
        writeProgress = streamOutput ? WriteOperationProgress(title: title) : nil
        if streamOutput {
            result = "\(title)进行中…\n"
        }
        operationTask = Task {
            defer {
                checkoutProgress = nil
                operation = ""
                operationTask = nil
            }
            do {
                try await action()
                if streamOutput {
                    writeProgress?.phase = .completed
                    writeProgress?.finishedAt = Date()
                    result = "\(title)完成\n\n" + result
                }
            } catch {
                if let reportFailure {
                    reportFailure(error)
                    return
                }
                let cancelled = error is CancellationError || Task.isCancelled
                var detail = cancelled
                    ? cancellationMessage ?? "操作已中断；已产生的本地变更不会自动撤销。请刷新状态后检查。"
                    : error.localizedDescription
                if streamOutput, writeProgress?.phase == .completed {
                    detail = cancelled ? "\(title)已完成，但状态刷新已取消；请刷新检查，不要重复执行。" : error.localizedDescription
                }
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
                if streamOutput {
                    let phase: WriteOperationProgress.Phase = writeProgress?.phase == .completed
                        ? .completedWithWarning : (cancelled ? .cancelled : .failed)
                    writeProgress?.phase = phase
                    writeProgress?.finishedAt = Date()
                    result = "\(title)：\(phase.rawValue)\n\n" + result + "\n\n" + detail
                } else {
                    result = detail
                }
            }
        }
    }
}
