import SwiftUI
import SVNCore

struct ReleaseCheckView: View {
    static let windowID = "release-check"
    @StateObject private var checker = ReleaseChecker()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceHeading(title: L10n.text("检查新版本"), icon: "arrow.down.circle")
            Group {
                switch checker.state {
                case .idle, .checking:
                    ProgressView(L10n.text("正在检查新版本…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let error):
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .checked(let result):
                    Text(summary(result.comparison)).font(.headline)
                    Text(L10n.text("当前版本 %@ · 最新正式版 %@", result.currentVersion, result.release.tag_name))
                    Text(L10n.text("发布时间：%@", result.release.published_at.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(result.release.body?.isEmpty == false ? result.release.body! : L10n.text("该版本未提供发布说明。"))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12).modifier(WorkspacePanel())
                    Link(L10n.text("打开发布页面与下载"), destination: result.release.html_url)
                    Text(L10n.text("检查于 %@", result.checkedAt.formatted(date: .abbreviated, time: .standard)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L10n.text("重新检查")) { checker.check() }.disabled(checker.isChecking)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 720, height: 550)
        .modifier(WorkspaceBackground())
        .onAppear { checker.check() }
        .onDisappear { checker.cancel() }
    }

    private func summary(_ comparison: ComparisonResult) -> String {
        switch comparison {
        case .orderedAscending: return L10n.text("发现新版本")
        case .orderedSame: return L10n.text("当前已是最新正式版")
        case .orderedDescending: return L10n.text("本地版本高于最新正式版")
        }
    }
}
