import AppKit
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
    @ViewState private var versions: HistoricalFileVersions?
    @ViewState private var exportTask: Task<Void, Never>?
    @ViewState private var exportMessage: String?
    @ViewState private var exportFailed = false
    @ViewState private var exportedURL: URL?
    @ViewState private var exportWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            if request.change.kind != "dir", let versions {
                exportBar(versions)
                Divider()
            }
            if failure != nil {
                HStack {
                    Label(L10n.text("历史差异读取失败"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Spacer()
                    Button(L10n.text("重试")) { attempt += 1 }
                }
                .padding(12)
            } else if comparison == nil {
                ProgressView(L10n.text("正在从仓库读取历史差异…")).padding(12)
            }
            DiffContentView(
                title: request.change.path,
                subtitle: "r\(request.revision) · \(request.change.label)"
                    + (request.change.kind == "dir" ? L10n.text(" · 仅当前目录属性，不包含子项") : "")
                    + (request.change.copyFromPath.map { L10n.text(" · 复制自 %@ @ r%@", $0, request.change.copyFromRevision ?? "") } ?? ""),
                text: failure ?? comparison?.text ?? L10n.text("正在读取…"),
                oldLabel: comparison?.oldLabel ?? L10n.text("读取比较版本中…"),
                newLabel: comparison?.newLabel ?? "r\(request.revision)",
                footer: comparisonSummary
            )
        }
        .modifier(WorkspaceBackground())
        .task(id: attempt) {
            comparison = nil
            failure = nil
            do {
                versions = try request.client.historicalFileVersions(
                    change: request.change, revision: request.revision
                )
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
        .background(ViewWindowReader { exportWindow = $0 })
        .onDisappear { exportTask?.cancel() }
    }

    /// 从实际比较版本生成摘要，保留新增、删除及复制来源含义，不重复长路径。
    private var comparisonSummary: String {
        guard comparison != nil, let versions else {
            return L10n.text("历史查看不会修改工作副本")
        }
        let before = versions.before.map {
            "r\($0.revision)" + ($0.isCopySource ? L10n.text("（复制来源）") : "")
        } ?? L10n.text("前版本不存在")
        let after = versions.after.map { "r\($0.revision)" }
            ?? L10n.text("r%@（已删除）", request.revision)
        return L10n.text("%@ → %@ · 只读", before, after)
    }

    private func exportBar(_ versions: HistoricalFileVersions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("导出历史文件"), systemImage: "square.and.arrow.down")
                Spacer()
                if let before = versions.before {
                    Button(before.isCopySource ? L10n.text("导出复制来源…") : L10n.text("导出前版本…")) { export(before) }
                        .help(before.label)
                } else {
                    Text(L10n.text("前版本不存在")).foregroundStyle(.secondary)
                }
                if let after = versions.after {
                    Button(L10n.text("导出后版本…")) { export(after) }.help(after.label)
                } else {
                    Text(L10n.text("后版本已删除")).foregroundStyle(.secondary)
                }
            }
            .disabled(exportTask != nil)
            if let message = exportMessage {
                HStack {
                    if exportTask != nil { ProgressView().controlSize(.small) }
                    Text(message)
                        .foregroundStyle(exportFailed ? .red : .secondary)
                        .textSelection(.enabled)
                    Spacer()
                    if exportTask != nil {
                        Button(L10n.text("取消导出")) { exportTask?.cancel() }
                    } else if let exportedURL {
                        Button(L10n.text("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                    }
                }
            }
        }
        .font(.caption)
        .padding(12)
        .background(.bar)
    }

    /// 用户选择位置后才读取并保存；完整读取成功前不触碰目标，关闭弹窗会取消在途导出。
    private func export(_ version: HistoricalFileVersion) {
        guard let window = exportWindow else {
            exportFailed = true
            exportMessage = L10n.text("未能定位历史窗口，请关闭后重新打开。")
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出历史文件")
        panel.message = version.label + L10n.text("\n保存仓库原始文件内容，不包含 SVN 属性。")
        panel.nameFieldStringValue = version.suggestedFilename
        panel.directoryURL = request.directory.deletingLastPathComponent()
        panel.canCreateDirectories = true
        // 历史视图本身已经是 sheet，使用异步面板，避免嵌套同步模态循环阻塞界面。
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            save(version, to: destination)
        }
    }

    private func save(_ version: HistoricalFileVersion, to destination: URL) {
        let root = request.directory.resolvingSymlinksInPath().path
        let target = destination.resolvingSymlinksInPath().path
        guard target != root, !target.hasPrefix(root + "/") else {
            exportFailed = true
            exportedURL = nil
            exportMessage = L10n.text("请选择当前工作副本以外的位置，避免覆盖本地工作文件。")
            return
        }
        exportFailed = false
        exportedURL = nil
        exportMessage = L10n.text("正在导出 %@…", version.label)
        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let data = try await request.client.historicalFileContent(version, at: request.directory)
                try Task.checkCancellation()
                try data.write(to: destination, options: .atomic)
                exportedURL = destination
                exportMessage = L10n.text("已导出：%@", destination.path)
            } catch is CancellationError {
                exportMessage = L10n.text("导出已取消，目标文件未写入。")
            } catch {
                exportFailed = true
                exportMessage = error.localizedDescription
            }
        }
    }
}
