import SwiftUI
import SVNCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onLogin: () -> Void

    private var selectedLog: LogEntry? {
        model.logs.first { $0.revision == model.selectedHistoryRevision }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近 50 次提交").font(.headline)
                Text("从仓库读取").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新加载") { model.loadHistory() }.disabled(model.isBusy)
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
                    Button("重试") { model.loadHistory() }.disabled(model.isBusy)
                }
            case .loaded:
                if model.logs.isEmpty {
                    ContentUnavailableView("暂无历史记录", systemImage: "clock", description: Text("仓库未返回当前路径的提交记录。"))
                } else {
                    historyContents
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyContents: some View {
        HSplitView {
            List(selection: $model.selectedHistoryRevision) {
                ForEach(model.logs) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("r\(log.revision)").font(.system(.headline, design: .monospaced))
                            Text(log.author).font(.subheadline)
                            Spacer()
                            Text("\(log.changedPaths.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(log.message.isEmpty ? "（无提交说明）" : log.message)
                            .lineLimit(3)
                        Text(log.date).font(.caption).foregroundStyle(.secondary)
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
                                Text(change.action)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(actionColor(change))
                                    .frame(width: 24, height: 24)
                                    .background(actionColor(change).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
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
