import SwiftUI
import SVNCore

/// 主工作区与访达提交复用同一份辅助检查和实际范围，建议不改变提交选择。
struct CommitReviewContent: View {
    let plan: CommitPlan
    @ViewState private var showNearby = true
    @ViewState private var showTemporary = true
    @ViewState private var showScope = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary
                if !plan.assistance.temporaryItems.isEmpty {
                    DisclosureGroup(
                        L10n.text("新增内容中的疑似临时文件：%@ 项", plan.assistance.temporaryItems.count),
                        isExpanded: $showTemporary
                    ) {
                        advisoryRows(plan.assistance.temporaryItems)
                    }
                }
                if !plan.assistance.nearbyNewItems.isEmpty {
                    DisclosureGroup(
                        L10n.text("附近未纳入本次提交的新项目：%@ 项", plan.assistance.nearbyNewItems.count),
                        isExpanded: $showNearby
                    ) {
                        Text(L10n.text("这些项目与提交项位于同一目录，或位于待提交目录内，不一定属于本次任务。需要时返回工作区添加或勾选；访达入口可关闭后在主工作区处理。"))
                            .font(.caption).foregroundStyle(.secondary)
                        advisoryRows(plan.assistance.nearbyNewItems)
                    }
                }
                Divider()
                DisclosureGroup(
                    L10n.text("实际提交范围：%@ 项", plan.items.count), isExpanded: $showScope
                ) {
                    Text(L10n.text("目录删除、替换和带历史复制会包含子项；移动两端及尚未提交的父目录也必须一并提交。以下为本次实际范围，返回后可重新选择。"))
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.path)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("\(item.change.label) · \(item.reason)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .modifier(WorkspacePanel())
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("提交前辅助检查"), systemImage: "checklist")
                .font(.headline)
            Text(L10n.text("本次包含 %@ 个文件、%@ 个目录", plan.assistance.fileCount, plan.assistance.directoryCount))
            Text(plan.assistance.changes.map { "\($0.change.label) \($0.count)" }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            if !plan.assistance.hasSuggestions {
                Text(L10n.text("未发现符合当前规则的提示，仍请核对实际提交范围。"))
                    .font(.callout)
            }
            Text(L10n.text("提示仅供参考，不会改变提交范围。新项目检查不含已忽略项，未受控目录仅列目录；临时文件仅按新增或替换文件的名称判断。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func advisoryRows(_ items: [CommitAdvisory]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}
