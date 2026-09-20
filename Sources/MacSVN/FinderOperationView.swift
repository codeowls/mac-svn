import SwiftUI
import SVNCore

struct FinderInboxItem: Identifiable {
    let id = UUID()
    let request: FinderRequest?
    let error: String?

    init(url: URL) {
        do {
            request = try FinderRequest(url: url)
            error = nil
        } catch {
            request = nil
            self.error = error.localizedDescription
        }
    }
}

/// One visible request at a time; later requests cannot overwrite a commit draft.
struct FinderInboxPresenter: ViewModifier {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { delegate.finderRequests.first },
            set: { value in
                if value == nil, !delegate.finderRequests.isEmpty {
                    delegate.finderRequests.removeFirst()
                }
            }
        )) { item in
            FinderOperationView(model: model, item: item)
                .id(item.id)
                .interactiveDismissDisabled()
        }
    }
}

/// Separate form state preserves the main workspace's selection, message and current repository.
struct FinderOperationView: View {
    @ObservedObject var model: AppModel
    let item: FinderInboxItem
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: FinderSelection?
    @ViewState private var entries: [StatusEntry] = []
    @ViewState private var selected = Set<String>()
    @ViewState private var message = ""
    @ViewState private var plan: CommitPlan?
    @ViewState private var output = ""
    @ViewState private var error: String?
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var completed = false
    @ViewState private var nextHistoryRevision: Int?

    @ViewState private var showLogin = false

    private var action: FinderRequest.Action? { item.request?.action }
    private var busy: Bool { task != nil }

    private var title: String {
        switch action {
        case .commit: L10n.text("访达：提交所选项目")
        case .update: L10n.text("访达：更新整个工作副本")
        case .diff: L10n.text("访达：查看差异")
        case .history: L10n.text("访达：查看历史")
        case .open: L10n.text("访达：打开工作副本")
        case nil: L10n.text("访达操作")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceHeading(title: title, icon: "folder.badge.gearshape")
            if let selection {
                Text(selection.workingCopy.root.path).font(.callout).textSelection(.enabled)
                Text(selection.workingCopy.repositoryURL).font(.caption).textSelection(.enabled)
                if action == .commit, !completed {
                    commitForm
                } else if action == .update {
                    Text(L10n.text("将更新整个工作副本，包含未在访达中选中的项目。"))
                }
            } else {
                Text(item.request?.paths.joined(separator: "\n") ?? "").textSelection(.enabled)
            }
            if let detail = item.error ?? error {
                Text(detail).foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollView {
                Text(output).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if action == .history, nextHistoryRevision != nil {
                Button(L10n.text("加载更早记录")) { loadEarlierHistory() }.disabled(busy || model.isBusy)
            }
            if busy { ProgressView() }
            HStack {
                if busy {
                    Button(L10n.text("取消")) { task?.cancel() }
                } else {
                    Button(L10n.text("关闭")) { dismiss() }
                }
                Spacer()
                if selection != nil, !completed, plan == nil {
                    Button(L10n.text("刷新本地状态")) { load() }.disabled(busy || model.isBusy)
                }
                if selection != nil {
                    Button(L10n.text("仓库账号")) { showLogin = true }.disabled(busy || model.isBusy)
                }
                if selection == nil, item.request != nil {
                    Button(L10n.text("读取工作副本")) { load() }.disabled(busy || model.isBusy)
                } else if action == .update, !completed {
                    Button(L10n.text("确认更新整个工作副本")) { update() }.disabled(busy || model.isBusy)
                } else if action == .open, let selection {
                    Button(L10n.text("打开工作副本…")) {
                        model.open(selection.workingCopy.root)
                        dismiss()
                    }.disabled(busy || model.isBusy)
                }
            }
        }
        .padding(24)
        .frame(width: 740, height: 600)
        .modifier(WorkspaceBackground())
        .onAppear { error = item.error; load() }
        .sheet(isPresented: $showLogin) {
            if let selection {
                RepositoryLoginView(model: model, repository: selection.workingCopy.repositoryURL)
            }
        }
    }

    @ViewBuilder private var commitForm: some View {
        if let plan {
            Text(L10n.text("确认提交范围：%@ 项", plan.items.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.items) { entry in
                        Text(entry.path).font(.system(.body, design: .monospaced))
                        Text(entry.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            Text(plan.message).textSelection(.enabled)
            HStack {
                Button(L10n.text("返回检查")) { self.plan = nil }
                Button(L10n.text("提交到仓库")) { commit(plan) }
            }.disabled(busy || model.isBusy)
        } else {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(entries) { entry in
                        Toggle(isOn: Binding(
                            get: { selected.contains(entry.path) },
                            set: { if $0 { selected.insert(entry.path) } else { selected.remove(entry.path) } }
                        )) { Text("\(entry.label)  \(entry.path)") }
                        .disabled(!entry.canCommit || busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            Text(L10n.text("提交说明"))
            TextEditor(text: $message).frame(height: 70).disabled(busy)
            Button(L10n.text("检查实际提交范围")) { prepareCommit() }
                .disabled(busy || model.isBusy || selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func load() {
        guard let request = item.request else { return }
        run {
            let client = try model.client()
            let resolved = try await client.resolveFinderSelection(request)
            guard FinderIntegration.shared.includes(resolved.workingCopy.root) else {
                throw SVNError(L10n.text("此工作副本尚未启用访达集成，请先在设置中添加。"))
            }
            selection = resolved
            let scoped = try model.client(for: resolved.workingCopy.repositoryURL)
            switch request.action {
            case .commit:
                entries = try await scoped.status(at: resolved.workingCopy.root).filter { entry in
                    resolved.relativePaths.contains { FinderRequest.contains(entry.path, in: $0) }
                }
                selected = Set(entries.filter(\.canCommit).map(\.path))
                output = entries.isEmpty ? L10n.text("当前没有本地变更") : ""
            case .diff:
                guard resolved.relativePaths.count == 1 else {
                    throw SVNError(L10n.text("请只选择一个项目查看差异或历史。"))
                }
                output = try await scoped.diff(path: resolved.relativePaths[0], at: resolved.workingCopy.root)
            case .history:
                guard resolved.relativePaths.count == 1 else {
                    throw SVNError(L10n.text("请只选择一个项目查看差异或历史。"))
                }
                let page = try await scoped.historyPage(at: resolved.workingCopy.root, path: resolved.relativePaths[0])
                output = historyText(page)
                nextHistoryRevision = page.nextBeforeRevision
            case .update, .open:
                break
            }
        }
    }

    private func historyText(_ page: HistoryPage) -> String {
        page.entries.map { "r\($0.revision)  \($0.author)  \($0.date)\n\($0.message)" }
            .joined(separator: "\n\n")
    }

    /// Advance only after a successful page read, allowing retries without losing earlier records.
    private func loadEarlierHistory() {
        guard let selection, selection.relativePaths.count == 1, let before = nextHistoryRevision else { return }
        run {
            let page = try await model.client(for: selection.workingCopy.repositoryURL).historyPage(
                at: selection.workingCopy.root, path: selection.relativePaths[0], beforeRevision: before
            )
            output += "\n\n" + historyText(page)
            nextHistoryRevision = page.nextBeforeRevision
        }
    }

    private func prepareCommit() {
        guard let selection else { return }
        run {
            plan = try await model.client(for: selection.workingCopy.repositoryURL)
                .prepareCommit(paths: selected.sorted(), message: message, at: selection.workingCopy.root)
        }
    }

    private func commit(_ reviewed: CommitPlan) {
        guard let selection else { return }
        run {
            plan = nil
            try await write(at: selection.workingCopy.root) { onOutput in
                try await model.client(for: selection.workingCopy.repositoryURL).commit(reviewed, onOutput: onOutput)
            }
        }
    }

    private func update() {
        guard let selection else { return }
        run {
            try await write(at: selection.workingCopy.root) { onOutput in
                try await model.client(for: selection.workingCopy.repositoryURL)
                    .update(at: selection.workingCopy.root, onOutput: onOutput)
            }
            let status = try await model.client(for: selection.workingCopy.repositoryURL).status(at: selection.workingCopy.root)
            if status.contains(where: \.isConflict) {
                output += "\n" + L10n.text("更新产生冲突，请在主工作区查看并处理。")
            }
        }
    }

    /// Drain live output before publishing completion, then refresh even after a cancelled write.
    private func write(
        at root: URL,
        action: (@escaping @Sendable (String) -> Void) async throws -> String
    ) async throws {
        guard FinderIntegration.shared.includes(root), let request = item.request else {
            throw SVNError(L10n.text("此工作副本尚未启用访达集成，请先在设置中添加。"))
        }
        let current = try await model.client().resolveFinderSelection(request)
        guard current.workingCopy.root.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else {
            throw SVNError(L10n.text("工作副本位置已变化，请重新从访达选择。"))
        }
        output = ""
        let stream = CommandOutputStream()
        let reader = Task { @MainActor in
            for await text in stream.stream { output += text }
        }
        var failure: Error?
        do {
            _ = try await action { stream.append($0) }
            completed = true
        } catch {
            failure = error
        }
        stream.finish()
        await reader.value
        let refresh = Task { @MainActor in try await model.refreshAfterFinderWrite(at: root) }
        do {
            try await refresh.value
        } catch {
            output += "\n" + L10n.text("重新读取状态失败：%@", error.localizedDescription)
        }
        if let failure { throw failure }
    }

    /// Share the host operation lock while keeping all Finder form state local to this sheet.
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        error = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try await model.performFinderOperation(operation)
            } catch {
                self.error = error is CancellationError || Task.isCancelled
                    ? L10n.text("操作已取消；写操作结果可能已生效，请核对状态和历史后再重试。")
                    : error.localizedDescription
            }
        }
    }
}
