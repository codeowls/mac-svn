import AppKit
import SwiftUI
import SVNCore

struct ConflictView: View {
    @ObservedObject var model: AppModel
    let details: ConflictDetails
    @ViewState private var selectedFile = "working"
    @ViewState private var preview = ""
    @ViewState private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("冲突详情"), icon: "exclamationmark.triangle", color: .orange)
            Text(details.entry.path).font(.headline).textSelection(.enabled)
            ForEach(Array(details.summary.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).textSelection(.enabled)
            }
            if !details.canMarkResolved {
                Text(L10n.text("属性和树冲突请使用 SVN 命令行或专用合并工具处理。本窗口提供详情，不会连带接受其他类型的冲突。"))
                    .font(.callout).foregroundStyle(.orange)
            }
            if !details.files.isEmpty {
                Picker(L10n.text("查看版本"), selection: $selectedFile) {
                    ForEach(details.files) { file in Text(file.title).tag(file.id) }
                }
                if let file = details.files.first(where: { $0.id == selectedFile }) {
                    Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let previewError {
                        Text(previewError).foregroundStyle(.red).textSelection(.enabled)
                    }
                    OperationOutputView(text: preview, followsOutput: false, accessibilityLabel: L10n.text("冲突版本内容"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .modifier(WorkspacePanel())
                }
            } else {
                Text(L10n.text("该冲突没有可查看的本地辅助文件。"))
                Spacer()
            }
            if let error = model.conflictError {
                Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            if details.canMarkResolved {
                DisclosureGroup(L10n.text("外部合并将使用的文件")) {
                    ForEach(details.files) { file in
                        Text("\(file.title)：\(file.url.path)")
                            .font(.caption).textSelection(.enabled)
                    }
                    Text(L10n.text("保存目标为当前工作文件；其余三个版本用作合并输入。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let activity = model.externalMergeActivity,
               activity.root == details.root, activity.path == details.entry.path {
                Text(activity.message).font(.caption).textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("打开或关闭编辑器不会自动解除冲突。编辑完成后，检查最终工作文件并明确确认；标记解决仍不会自动提交。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([details.root.appendingPathComponent(details.entry.path)])
                }
                if details.canMarkResolved, details.files.contains(where: { $0.id == "working" }) {
                    Button(L10n.text("编辑工作文件")) { openWorkingFile() }
                    Button(L10n.text("外部合并…")) { model.openExternalMerge(details) }
                        .disabled(model.externalMergeActivity?.isRunning == true)
                }
                Button(L10n.text("重新读取")) { model.inspectConflict(path: details.entry.path) }
                Spacer()
                Button(L10n.text("关闭")) { model.conflictDetails = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.text("检查解决结果…")) { model.prepareConflictResolution(details) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!details.canMarkResolved || model.isExternallyMerging(details))
            }
            .disabled(model.isBusy)
        }
        .padding(24)
        .frame(width: 900, height: 680)
        .modifier(WorkspaceBackground())
        .onAppear {
            selectedFile = details.files.first(where: { $0.id == "prop-file" })?.id
                ?? details.files.first?.id ?? "working"
        }
        .task(id: "\(details.id)/\(selectedFile)") {
            preview = L10n.text("正在读取…")
            previewError = nil
            guard let file = details.files.first(where: { $0.id == selectedFile }) else { return }
            do {
                let client = try model.client()
                let data = try await Task.detached {
                    try client.conflictFileContent(file, at: details.root)
                }.value
                try Task.checkCancellation()
                preview = String(data: data, encoding: .utf8)
                    ?? L10n.text("该文件不是 UTF-8 文本（%@ 字节），请使用合适的外部编辑器查看。", data.count)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                preview = ""
                previewError = error.localizedDescription
            }
        }
        .sheet(item: $model.conflictResolutionPlan) { plan in
            ConflictResolutionView(model: model, plan: plan)
        }
    }

    private func openWorkingFile() {
        guard let file = details.files.first(where: { $0.id == "working" }) else { return }
        do {
            // 与预览共用路径及普通文件检查，不能通过冲突路径打开副本外的符号链接。
            _ = try model.client().conflictFileContent(file, at: details.root)
            guard NSWorkspace.shared.open(file.url) else {
                throw SVNError(L10n.text("无法用默认应用打开该文件，请在访达中选择合适的编辑器。"))
            }
        } catch {
            model.conflictError = error.localizedDescription
        }
    }
}

private struct ConflictResolutionView: View {
    @ObservedObject var model: AppModel
    let plan: ConflictResolutionPlan
    @ViewState private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("检查最终工作文件"), icon: "doc.text.magnifyingglass")
            Text(plan.details.entry.path).font(.headline).textSelection(.enabled)
            Text(L10n.text("将保留下面的当前内容并解除该文件的内容冲突。SVN 会移除该冲突的辅助文件；其他文件及属性／树冲突不会一起解决。"))
                .font(.callout)
            if plan.containsConflictMarkers {
                Text(L10n.text("检测到疑似冲突标记（<<<<<<<、||||||| 或 >>>>>>>）。请确认这些确实是需要保留的正文，否则返回手动合并。"))
                    .foregroundStyle(.red).font(.callout)
            }
            OperationOutputView(text: plan.preview, followsOutput: false, accessibilityLabel: L10n.text("最终工作文件"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .modifier(WorkspacePanel())
            Toggle(L10n.text("我已检查最终内容，确认采用当前工作文件"), isOn: $confirmed)
            HStack {
                Spacer()
                Button(L10n.text("返回检查"), role: .cancel) { model.conflictResolutionPlan = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("确认标记已解决")) { model.confirmConflictResolution(plan) }
                    .buttonStyle(.borderedProminent).disabled(!confirmed || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 720, height: 510)
        .modifier(WorkspaceBackground())
    }
}
