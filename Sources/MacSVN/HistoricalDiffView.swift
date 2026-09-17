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
        .background(HistoricalExportWindowReader { exportWindow = $0 })
        .onDisappear { exportTask?.cancel() }
    }

    private func exportBar(_ versions: HistoricalFileVersions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("导出历史文件", systemImage: "square.and.arrow.down")
                Spacer()
                if let before = versions.before {
                    Button(before.isCopySource ? "导出复制来源…" : "导出前版本…") { export(before) }
                        .help(before.label)
                } else {
                    Text("前版本不存在").foregroundStyle(.secondary)
                }
                if let after = versions.after {
                    Button("导出后版本…") { export(after) }.help(after.label)
                } else {
                    Text("后版本已删除").foregroundStyle(.secondary)
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
                        Button("取消导出") { exportTask?.cancel() }
                    } else if let exportedURL {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                    }
                }
            }
        }
        .font(.caption)
        .padding(12)
    }

    /// 用户选择位置后才读取并保存；完整读取成功前不触碰目标，关闭弹窗会取消在途导出。
    private func export(_ version: HistoricalFileVersion) {
        guard let window = exportWindow else {
            exportFailed = true
            exportMessage = "未能定位历史窗口，请关闭后重新打开。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出历史文件"
        panel.message = version.label + "\n保存仓库原始文件内容，不包含 SVN 属性。"
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
            exportMessage = "请选择当前工作副本以外的位置，避免覆盖本地工作文件。"
            return
        }
        exportFailed = false
        exportedURL = nil
        exportMessage = "正在导出 \(version.label)…"
        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let data = try await request.client.historicalFileContent(version, at: request.directory)
                try Task.checkCancellation()
                try data.write(to: destination, options: .atomic)
                exportedURL = destination
                exportMessage = "已导出：\(destination.path)"
            } catch is CancellationError {
                exportMessage = "导出已取消，目标文件未写入。"
            } catch {
                exportFailed = true
                exportMessage = error.localizedDescription
            }
        }
    }
}

/// 绑定实际承载视图的窗口；后台或辅助功能触发按钮时，App 的 keyWindow 可能为空。
private struct HistoricalExportWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange?(window)
            }
        }
    }
}
