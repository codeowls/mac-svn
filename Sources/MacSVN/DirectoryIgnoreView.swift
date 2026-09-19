import SwiftUI
import SVNCore

struct DirectoryIgnoreView: View {
    @ObservedObject var model: AppModel
    let draft: DirectoryIgnoreDraft
    @ViewState private var patterns: String

    init(model: AppModel, draft: DirectoryIgnoreDraft) {
        self.model = model
        self.draft = draft
        _patterns = ViewState(initialValue: draft.initialPatterns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("目录忽略规则"), icon: "line.3.horizontal.decrease.circle")
            Text(draft.settings.root.appendingPathComponent(draft.settings.path).standardizedFileURL.path)
                .font(.caption).textSelection(.enabled)
            Text(L10n.text("每行一个名称或通配符，例如 build 或 *.log；名称中的空格会保留。规则只影响该目录的直接子项，已受控文件不受影响。"))
                .font(.callout)
            TextEditor(text: $patterns)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .modifier(WorkspacePanel())
                .disabled(model.isBusy)
                .accessibilityLabel(L10n.text("目录忽略规则，每行一项"))
            Text(L10n.text("保存会修改该目录的 svn:ignore 属性，提交目录后才会共享。删除某行可撤销该规则，清空并保存可移除此属性；全局及祖先的忽略规则仍然有效。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.directoryIgnoreError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("取消"), role: .cancel) { model.directoryIgnoreDraft = nil }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(L10n.text("保存规则")) { model.saveDirectoryIgnores(draft, patterns: patterns) }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 640, height: 480)
        .modifier(WorkspaceBackground())
        .interactiveDismissDisabled(model.isBusy)
    }
}
