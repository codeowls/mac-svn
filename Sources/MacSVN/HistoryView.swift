import AppKit
import SwiftUI
import SVNCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onLogin: () -> Void
    @ViewState private var diffRequest: HistoricalDiffRequest?
    @ViewState private var hoveredPath: String?

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
        guard !value.isEmpty else { return L10n.text("（未提供时间）") }
        do {
            let date = try Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")))
            return Self.displayDateFormatter.string(from: date)
        } catch {
            return L10n.text("时间格式无效：%@", value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.text("提交历史"), systemImage: "clock.arrow.circlepath").font(.headline)
                    Spacer()
                    if model.historyPath != "." {
                        Button(L10n.text("工作副本历史")) { model.loadHistory() }.disabled(model.isBusy)
                    }
                    Button(L10n.text("选择文件…")) { model.chooseFileHistory() }.disabled(model.isBusy)
                    Button(L10n.text("重新加载")) { model.reloadHistory() }.disabled(model.isBusy)
                }
                Text(model.historyPath == "." ? L10n.text("范围：当前工作副本路径") : L10n.text("范围：%@", model.historyPath))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.historyPath)
                HStack {
                    TextField(L10n.text("筛选作者"), text: $model.historyFilter.author)
                    TextField(L10n.text("筛选提交说明"), text: $model.historyFilter.message)
                    TextField(L10n.text("筛选变更路径"), text: $model.historyFilter.path)
                    Button(L10n.text("清除")) { model.historyFilter = HistoryFilter() }
                        .disabled(model.historyFilter.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                Text(L10n.text("筛选仅作用于已加载记录，多个条件同时匹配；可继续加载更早记录。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))
            Divider()
            switch model.historyState {
            case .idle:
                ContentUnavailableView(L10n.text("尚未读取历史"), systemImage: "clock", description: Text(L10n.text("点击重新加载，从当前仓库读取提交记录。")))
            case .loading:
                ProgressView(L10n.text("正在读取提交记录与变更文件…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message, let requiresAuthentication):
                ContentUnavailableView {
                    Label(L10n.text("无法读取提交历史"), systemImage: requiresAuthentication ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    if requiresAuthentication {
                        Button(L10n.text("登录仓库"), action: onLogin)
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }
                    Button(L10n.text("重试")) { model.reloadHistory() }.disabled(model.isBusy)
                }
            case .loaded:
                if model.logs.isEmpty {
                    ContentUnavailableView(L10n.text("暂无历史记录"), systemImage: "clock", description: Text(L10n.text("仓库未返回当前路径的提交记录。")))
                } else if model.filteredLogs.isEmpty {
                    ContentUnavailableView(L10n.text("没有匹配的历史记录"), systemImage: "magnifyingglass", description: Text(L10n.text("请调整筛选条件，或加载更早记录后继续查找。")))
                } else {
                    historyContents
                }
                historyFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .modifier(WorkspacePanel())
        .padding(16)
        .onChange(of: model.historyFilter) { _, _ in model.reconcileHistorySelection() }
        .onChange(of: model.workingCopy?.root) { _, _ in diffRequest = nil }
        .sheet(item: $diffRequest) { HistoricalDiffView(request: $0) }
    }

    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.historyPageError {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if model.historyPageRequiresAuthentication {
                    Button(L10n.text("登录仓库"), action: onLogin).disabled(model.isBusy)
                }
            }
            HStack {
                Text(L10n.text("已加载 %@ 条 · 匹配 %@ 条", model.logs.count, model.filteredLogs.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingMoreHistory {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在加载更早记录…")).font(.caption)
                } else if model.nextHistoryRevision != nil {
                    Button(model.historyPageError == nil ? L10n.text("加载更早记录") : L10n.text("重试加载更早记录")) {
                        model.loadMoreHistory()
                    }
                    .disabled(model.isBusy)
                } else {
                    Text(L10n.text("已加载全部可见历史")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025))
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
                            Text(L10n.text("%@ 项", log.changedPaths.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(log.message.isEmpty ? L10n.text("（无提交说明）") : log.message)
                            .lineLimit(3)
                        Text(formattedDate(log.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .tag(log.revision)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.primary.opacity(0.025))
            .frame(minWidth: 260, idealWidth: 340)
            if let log = selectedLog {
                changedFiles(log)
            } else {
                ContentUnavailableView(L10n.text("选择一条提交记录"), systemImage: "doc.text.magnifyingglass")
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 路径沿用仓库返回的绝对路径；复制来源单独展示，不将复制加删除猜测为重命名。
    private func changedFiles(_ log: LogEntry) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("history-detail-top")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            WorkspaceBadge(title: "r\(log.revision)", color: WorkspaceStyle.accent)
                            Text(log.author.isEmpty ? L10n.text("（未提供作者）") : log.author)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        Text(formattedDate(log.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(log.message.isEmpty ? L10n.text("（无提交说明）") : log.message)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    Divider()
                    HStack {
                        Label(L10n.text("变更文件"), systemImage: "doc.on.doc")
                            .font(.headline)
                        Spacer()
                        Text(L10n.text("%@ 项", log.changedPaths.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    if log.changedPaths.isEmpty {
                        ContentUnavailableView(L10n.text("没有可显示的变更路径"), systemImage: "doc", description: Text(L10n.text("该记录未返回路径明细，可能受到仓库路径权限限制。")))
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log.changedPaths) { change in
                                Button {
                                    guard let copy = model.workingCopy else { return }
                                    do {
                                        diffRequest = HistoricalDiffRequest(
                                            change: change, revision: log.revision, directory: copy.root,
                                            client: try model.client(for: copy.repositoryURL)
                                        )
                                    } catch {
                                        model.errorMessage = error.localizedDescription
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: change.kind == "dir" ? "folder" : "doc.text")
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 4)
                                        VStack(alignment: .leading, spacing: 5) {
                                            WorkspacePathLabel(path: change.path)
                                            if let source = change.copyFromPath {
                                                Text(L10n.text("复制自 %@%@", source, change.copyFromRevision.map { " @ r\($0)" } ?? ""))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        WorkspaceBadge(title: change.label, color: actionColor(change))
                                            .fixedSize()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 4)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isBusy)
                                .background(hoveredPath == change.path && !model.isBusy ? Color.primary.opacity(0.05) : .clear)
                                .onHover { entered in
                                    hoveredPath = entered ? change.path : nil
                                }
                                .help(change.path)
                                .accessibilityLabel("\(change.path)、\(change.label)")
                                .accessibilityHint(L10n.text("查看该路径在此次提交中的差异"))
                                .contextMenu {
                                    Button(L10n.text("复制完整路径")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(change.path, forType: .string)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
            // 保持分栏视图身份稳定，只重置详情滚动位置。
            .onChange(of: log.revision) { _, _ in
                proxy.scrollTo("history-detail-top", anchor: .top)
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
