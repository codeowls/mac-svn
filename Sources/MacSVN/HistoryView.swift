import SwiftUI
import SVNCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onLogin: () -> Void
    @ViewState private var diffRequest: HistoricalDiffRequest?

    private var selectedLog: LogEntry? {
        model.filteredLogs.first { $0.revision == model.selectedHistoryRevision }
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// SVN 返回 UTC 时间，转换为本机时区并隐藏小数秒与时区标记。
    private func formattedDate(_ value: String) -> String {
        guard !value.isEmpty else { return "（未提供时间）" }
        do {
            let date = try Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")))
            return Self.displayDateFormatter.string(from: date)
        } catch {
            return "时间格式无效：\(value)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("提交历史").font(.headline)
                    Spacer()
                    if model.historyPath != "." {
                        Button("工作副本历史") { model.loadHistory() }.disabled(model.isBusy)
                    }
                    Button("选择文件…") { model.chooseFileHistory() }.disabled(model.isBusy)
                    Button("重新加载") { model.reloadHistory() }.disabled(model.isBusy)
                }
                Text(model.historyPath == "." ? "范围：当前工作副本路径" : "范围：\(model.historyPath)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.historyPath)
                HStack {
                    TextField("筛选作者", text: $model.historyFilter.author)
                    TextField("筛选提交说明", text: $model.historyFilter.message)
                    TextField("筛选变更路径", text: $model.historyFilter.path)
                    Button("清除") { model.historyFilter = HistoryFilter() }
                        .disabled(model.historyFilter.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                Text("筛选仅作用于已加载记录，多个条件同时匹配；可继续加载更早记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            switch model.historyState {
            case .idle:
                ContentUnavailableView("尚未读取历史", systemImage: "clock", description: Text("点击重新加载，从当前仓库读取提交记录。"))
            case .loading:
                ProgressView("正在读取提交记录与变更文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message, let requiresAuthentication):
                ContentUnavailableView {
                    Label("无法读取提交历史", systemImage: requiresAuthentication ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    if requiresAuthentication {
                        Button("登录仓库", action: onLogin)
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }
                    Button("重试") { model.reloadHistory() }.disabled(model.isBusy)
                }
            case .loaded:
                if model.logs.isEmpty {
                    ContentUnavailableView("暂无历史记录", systemImage: "clock", description: Text("仓库未返回当前路径的提交记录。"))
                } else if model.filteredLogs.isEmpty {
                    ContentUnavailableView("没有匹配的历史记录", systemImage: "magnifyingglass", description: Text("请调整筛选条件，或加载更早记录后继续查找。"))
                } else {
                    historyContents
                }
                historyFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.historyFilter) { _, _ in model.reconcileHistorySelection() }
        .onChange(of: model.workingCopy?.root) { _, _ in diffRequest = nil }
        .sheet(item: $diffRequest) { HistoricalDiffView(request: $0) }
    }

    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.historyPageError {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if model.historyPageRequiresAuthentication {
                    Button("登录仓库", action: onLogin).disabled(model.isBusy)
                }
            }
            HStack {
                Text("已加载 \(model.logs.count) 条 · 匹配 \(model.filteredLogs.count) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingMoreHistory {
                    ProgressView().controlSize(.small)
                    Text("正在加载更早记录…").font(.caption)
                } else if model.nextHistoryRevision != nil {
                    Button(model.historyPageError == nil ? "加载更早记录" : "重试加载更早记录") {
                        model.loadMoreHistory()
                    }
                    .disabled(model.isBusy)
                } else {
                    Text("已加载全部可见历史").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }

    private var historyContents: some View {
        HSplitView {
            List(selection: $model.selectedHistoryRevision) {
                ForEach(model.filteredLogs) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("r\(log.revision)").font(.system(.headline, design: .monospaced))
                            Text(log.author).font(.subheadline)
                            Spacer()
                            Text("\(log.changedPaths.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(log.message.isEmpty ? "（无提交说明）" : log.message)
                            .lineLimit(3)
                        Text(formattedDate(log.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .tag(log.revision)
                }
            }
            .frame(minWidth: 260, idealWidth: 340)
            if let log = selectedLog {
                changedFiles(log)
            } else {
                ContentUnavailableView("选择一条提交记录", systemImage: "doc.text.magnifyingglass")
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 路径沿用仓库返回的绝对路径；复制来源单独展示，不将复制加删除猜测为重命名。
    private func changedFiles(_ log: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("r\(log.revision) · 变更文件 \(log.changedPaths.count) 项").font(.headline)
                Text(log.message.isEmpty ? "（无提交说明）" : log.message)
                    .textSelection(.enabled).lineLimit(5).help(log.message)
                Text("路径相对于仓库根目录，包含目录变更；仅显示服务器授权返回的项目。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if log.changedPaths.isEmpty {
                ContentUnavailableView("没有可显示的变更路径", systemImage: "doc", description: Text("该记录未返回路径明细，可能受到仓库路径权限限制。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.changedPaths) { change in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: change.kind == "dir" ? "folder" : "doc.text")
                                    .foregroundStyle(.secondary).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(change.path).font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    Text(change.label).font(.caption).foregroundStyle(actionColor(change))
                                    if let source = change.copyFromPath {
                                        Text("复制自 \(source)\(change.copyFromRevision.map { " @ r\($0)" } ?? "")")
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button("查看差异") {
                                    guard let copy = model.workingCopy else { return }
                                    do {
                                        diffRequest = HistoricalDiffRequest(
                                            change: change, revision: log.revision, directory: copy.root,
                                            client: try model.client(for: copy.repositoryURL)
                                        )
                                    } catch {
                                        model.errorMessage = error.localizedDescription
                                    }
                                }
                                .disabled(model.isBusy)
                            }
                            .padding(12)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func actionColor(_ change: LogChangedPath) -> Color {
        switch change.action {
        case "A": .green
        case "D": .red
        case "M", "R": .orange
        default: .secondary
        }
    }
}
