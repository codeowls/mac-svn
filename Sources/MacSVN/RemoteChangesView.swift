import SwiftUI
import SVNCore

@MainActor
final class RemoteChangesState: ObservableObject, Identifiable {
    let id = UUID()
    let copy: WorkingCopy
    @Published var changes: RemoteChanges?
    @Published var error: String?
    @Published var isLoading = false

    init(copy: WorkingCopy) {
        self.copy = copy
    }
}

struct RemoteChangesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: RemoteChangesState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("更新前检查远端变化"), icon: "arrow.triangle.2.circlepath")
            Text(state.copy.root.path).font(.caption).textSelection(.enabled)
            Text(L10n.text("检查只读取当前检出范围，不下载或修改文件；externals 需单独检查。"))
                .font(.caption).foregroundStyle(.secondary)
            if state.isLoading {
                ProgressView(L10n.text("正在检查远端变化…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let changes = state.changes {
                Text(L10n.text("检查时远端版本 r%@ · %@ 个变化项目", changes.revision, changes.items.count))
                Text(changes.checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("重叠仅说明路径上存在本地变化，不代表一定产生冲突。检查后仓库仍可能变化，更新沿用正常 SVN 更新流程。"))
                    .font(.caption).foregroundStyle(.secondary)
                if changes.items.isEmpty {
                    ContentUnavailableView(L10n.text("没有远端变化"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(changes.items) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                                    ForEach(item.localOverlaps) { local in
                                        Label(L10n.text("本地重叠：%@ · %@", local.path, local.label), systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .padding(12)
                    .modifier(WorkspacePanel())
                }
            }
            HStack {
                Button(L10n.text("重新检查")) { model.readRemoteChanges(state) }
                    .disabled(model.isBusy)
                Spacer()
                Button(L10n.text("关闭")) { model.closeRemoteChanges(state) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("更新工作副本")) {
                    model.closeRemoteChanges(state)
                    model.update(at: state.copy.root)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || state.changes == nil || state.error != nil)
            }
        }
        .padding(24)
        .frame(width: 760, height: 600)
        .modifier(WorkspaceBackground())
    }
}
