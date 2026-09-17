import SwiftUI
import SVNCore

struct HistoricalDiffRequest: Identifiable {
    let id = UUID()
    let change: LogChangedPath
    let revision: String
    let directory: URL
    let client: SVNClient
}

struct HistoricalDiffView: View {
    let request: HistoricalDiffRequest
    @ViewState private var comparison: HistoricalDiff?
    @ViewState private var failure: String?
    @ViewState private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            if failure != nil {
                HStack {
                    Label("历史差异读取失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("重试") { attempt += 1 }
                }
                .padding(12)
            } else if comparison == nil {
                ProgressView("正在从仓库读取历史差异…").padding(12)
            }
            DiffContentView(
                title: request.change.path,
                subtitle: "r\(request.revision) · \(request.change.label)"
                    + (request.change.kind == "dir" ? " · 仅当前目录属性，不包含子项" : "")
                    + (request.change.copyFromPath.map { " · 复制自 \($0) @ r\(request.change.copyFromRevision ?? "")" } ?? ""),
                text: failure ?? comparison?.text ?? "正在读取…",
                oldLabel: comparison?.oldLabel ?? "读取比较版本中…",
                newLabel: comparison?.newLabel ?? "r\(request.revision)",
                footer: comparison.map { "\($0.oldLabel) → \($0.newLabel) · 只读" } ?? "历史查看不会修改工作副本"
            )
        }
        .task(id: attempt) {
            comparison = nil
            failure = nil
            do {
                let value = try await request.client.historicalDiff(
                    change: request.change, revision: request.revision, at: request.directory
                )
                try Task.checkCancellation()
                comparison = value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}
