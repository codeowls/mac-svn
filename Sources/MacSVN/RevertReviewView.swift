import SwiftUI
import SVNCore

struct RevertReviewView: View {
    let plan: RevertPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceHeading(title: "确认还原 \(plan.items.count) 个项目", icon: "arrow.uturn.backward", color: .red)
            Text(plan.root.path).font(.caption).textSelection(.enabled)
            Text("下面列出的未提交修改将永久丢弃，SVN 无法撤销此操作。还原只影响本地，不更改仓库提交历史。")
                .foregroundStyle(.red)
            Text("目录仅还原自身属性或新增安排，不递归还原未选子项；普通新增文件保留在磁盘，带历史复制文件会被删除。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.entry.path).font(.headline).textSelection(.enabled)
                            Text(item.entry.label + " · " + item.effect)
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup("查看将丢弃的差异") {
                                Text(item.preview).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(12)
            .modifier(WorkspacePanel())
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("确认丢弃并还原", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .modifier(WorkspaceBackground())
    }
}
