import SwiftUI
import SVNCore

struct WorkingCopyDepthView: View {
    @ObservedObject var model: AppModel
    let directory: WorkingCopyDepth
    @ViewState private var depth: CheckoutDepth
    @ViewState private var confirmed = false

    init(model: AppModel, directory: WorkingCopyDepth) {
        self.model = model
        self.directory = directory
        _depth = ViewState(initialValue: directory.depth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("调整检出深度"), icon: "arrow.down.to.line")
            Text(directory.root.appendingPathComponent(directory.path).standardizedFileURL.path)
                .font(.caption).textSelection(.enabled)
            Text(L10n.text("当前目录深度：%@。", (model.depthChangePlan?.directory ?? directory).depth.label))
            Text(L10n.text("子目录可能具有独立深度；检查范围会读取实际已检出的子项。"))
                .font(.caption).foregroundStyle(.secondary)
            if let plan = model.depthChangePlan {
                Text(L10n.text("目标深度：%@", plan.depth.label)).font(.headline)
                if plan.removedPaths.isEmpty {
                    Text(L10n.text("本次深度调整无需移除已检出的受控子项。"))
                } else {
                    Text(L10n.text("将从本地移除以下 %@ 个受控项目，仓库中的内容保留。", plan.removedPaths.count))
                        .foregroundStyle(.red)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(plan.removedPaths, id: \.self) { path in
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .modifier(WorkspacePanel())
                }
                Text(L10n.text("确认后会按目标深度更新到服务器最新版本，可能带入远端修改、删除或冲突。此操作不提交；以后普通更新沿用已保存的深度。"))
                    .font(.callout)
                Text(L10n.text("取消或失败不会回滚已完成的下载和移除，请根据操作日志重新检查目录。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("我已检查全部影响范围，确认执行"), isOn: $confirmed)
            } else {
                Picker(L10n.text("目标深度"), selection: $depth) {
                    ForEach(CheckoutDepth.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text(depth.explanation).font(.callout)
                Text(L10n.text("缩小范围前会检查本地修改、未受控和已忽略内容；确认前不会更改文件。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let error = model.depthChangeError {
                ScrollView {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            if model.isBusy {
                Button(L10n.text("取消操作")) { model.cancel() }
            }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("取消"), role: .cancel) {
                    model.depthDirectory = nil
                    model.depthChangePlan = nil
                }
                .keyboardShortcut(.cancelAction)
                if let plan = model.depthChangePlan {
                    Button(L10n.text("返回检查")) {
                        model.depthChangePlan = nil
                        model.depthChangeError = nil
                        confirmed = false
                    }
                    Button(L10n.text("确认调整")) { model.confirmDepthChange(plan) }
                        .buttonStyle(.borderedProminent).disabled(!confirmed)
                } else {
                    Button(L10n.text("检查影响范围")) { model.prepareDepthChange(directory, depth: depth) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(model.isBusy)
        }
        .padding(24)
        .frame(width: 700, height: 540)
        .modifier(WorkspaceBackground())
        .interactiveDismissDisabled(model.isBusy)
    }
}
