import Foundation
import SwiftUI
import SVNCore

struct FileOperationDraft: Identifiable {
    let id = UUID()
    let root: URL
    let operation: FileOperation
    let path: String
}

struct FileOperationView: View {
    @ObservedObject var model: AppModel
    let draft: FileOperationDraft
    @ViewState private var newName = ""
    @ViewState private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(
                title: "SVN \(draft.operation.title)",
                icon: draft.operation == .delete ? "trash" : "pencil",
                color: draft.operation == .delete ? .red : WorkspaceStyle.accent
            )
            Text(draft.path).font(.headline).textSelection(.enabled)
            if let plan = model.fileOperationPlan {
                if let destination = plan.destination {
                    Text(L10n.text("目标：%@", destination)).textSelection(.enabled)
                    Text(L10n.text("移动本地项目并保留已有 SVN 历史关联；原路径与目标路径需要一起提交。未提交的内容随文件移动。"))
                } else {
                    Text(L10n.text("将从磁盘删除下列项目，包括未提交修改、未受控及已忽略内容，已提交项目会安排 SVN 删除，尚未提交的新增项目会撤销新增安排。删除未提交内容无法通过 SVN 还原；已提交内容可从历史恢复。此操作不自动提交。"))
                        .foregroundStyle(.red)
                }
                Text(L10n.text("影响范围：%@ 项", plan.affectedPaths.count)).font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(plan.affectedPaths, id: \.self) { path in
                            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .modifier(WorkspacePanel())
                DisclosureGroup(L10n.text("查看当前状态与差异")) {
                    OperationOutputView(text: plan.preview, followsOutput: false)
                        .frame(height: 160)
                }
                Toggle(L10n.text("我已检查全部影响范围，确认执行"), isOn: $confirmed)
            } else {
                if draft.operation == .rename {
                    TextField(L10n.text("新名称"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.text("保留所在目录，仅修改名称。后续确认会列出源路径、目标路径和目录子项。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("先读取完整影响范围与本地变更，确认前不会删除文件。"))
                }
                Spacer()
            }
            if let error = model.fileOperationError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(L10n.text("取消"), role: .cancel) {
                    model.fileOperationDraft = nil
                    model.fileOperationPlan = nil
                }
                    .keyboardShortcut(.cancelAction)
                if let plan = model.fileOperationPlan {
                    Button(L10n.text("返回检查")) {
                        model.fileOperationPlan = nil
                        confirmed = false
                    }
                    Button(L10n.text("确认%@", draft.operation.title), role: draft.operation == .delete ? .destructive : nil) {
                        model.confirmFileOperation(plan)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(draft.operation == .delete ? .red : WorkspaceStyle.accent)
                    .disabled(!confirmed)
                } else {
                    Button(L10n.text("检查影响范围")) { model.prepareFileOperation(draft, newName: newName) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(model.isBusy)
        }
        .padding(24)
        .frame(width: 720, height: 570)
        .modifier(WorkspaceBackground())
        .onAppear { newName = (draft.path as NSString).lastPathComponent }
    }
}

struct CommitReviewView: View {
    @ObservedObject var model: AppModel
    let plan: CommitPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("确认提交范围：%@ 项", plan.items.count), icon: "checklist")
            Text(model.workingCopy?.repositoryURL ?? "").font(.caption).textSelection(.enabled)
            CommitReviewContent(plan: plan)
            ScrollView {
                Text(plan.message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 64)
            HStack {
                Spacer()
                Button(L10n.text("返回检查"), role: .cancel) { model.commitPlan = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.text("提交到仓库")) { model.commitSelected(plan) }.buttonStyle(.borderedProminent)
            }
            .disabled(model.isBusy)
        }
        .padding(24)
        .frame(width: 740, height: 620)
        .modifier(WorkspaceBackground())
    }
}
