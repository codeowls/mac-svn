import AppKit
import SwiftUI
import SVNCore

struct DiffView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DiffContentView(
            title: model.focusedPath ?? L10n.text("文件差异"),
            subtitle: model.entries.first { $0.path == model.focusedPath }?.label ?? L10n.text("文件差异"),
            text: model.diffText,
            oldLabel: L10n.text("原版本 · BASE"),
            newLabel: L10n.text("本地工作副本"),
            footer: L10n.text("对比本地基准版本与当前内容 · 不会修改文件"),
            fileURL: model.focusedPath.flatMap { model.workingCopy?.root.appendingPathComponent($0) }
        )
    }
}

/// 本地与历史差异共用渲染，版本标签由各自的实际比较对象提供。
struct DiffContentView: View {
    let title: String
    let subtitle: String
    let text: String
    let oldLabel: String
    let newLabel: String
    let footer: String
    var fileURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var sideBySide = false
    @ViewState private var document = UnifiedDiff("")
    @ViewState private var hunkIndex = 0
    @ViewState private var measuredColumnWidth: CGFloat = 0
    @ViewState private var measuredUnifiedWidth: CGFloat = 0
    @ViewState private var documentID = UUID()
    @ViewState private var scrollRequest: DiffScrollRequest?
    @ViewState private var isPreparing = true
    @ViewState private var preparationError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                if !document.hunkIDs.isEmpty {
                    HStack(spacing: 12) {
                        Picker(L10n.text("展示方式"), selection: $sideBySide) {
                            Text(L10n.text("统一")).tag(false)
                            Text(L10n.text("并排")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("展示方式"))
                        WorkspaceBadge(title: "+\(document.additions)", color: .green)
                        WorkspaceBadge(title: "−\(document.deletions)", color: .red)
                        Spacer()
                        Text(L10n.text("%@ / %@ 处变更", hunkIndex + 1, document.hunkIDs.count))
                            .foregroundStyle(.secondary)
                        Button {
                            hunkIndex -= 1
                            scrollRequest = DiffScrollRequest(lineID: document.hunkIDs[hunkIndex])
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(hunkIndex == 0)
                        .help(L10n.text("上一处变更"))
                        .accessibilityLabel(L10n.text("上一处变更"))
                        .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                        Button {
                            hunkIndex += 1
                            scrollRequest = DiffScrollRequest(lineID: document.hunkIDs[hunkIndex])
                        } label: { Image(systemName: "chevron.down") }
                        .disabled(hunkIndex == document.hunkIDs.count - 1)
                        .help(L10n.text("下一处变更"))
                        .accessibilityLabel(L10n.text("下一处变更"))
                        .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    .background(.bar)
                    Divider()
                }
                if sideBySide && !document.hunkIDs.isEmpty {
                    HStack {
                        Text(oldLabel).frame(maxWidth: .infinity, alignment: .leading)
                        Text(newLabel).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.035))
                    Divider()
                }
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width
                    let width = max((availableWidth - 1) / 2, measuredColumnWidth)
                    if isPreparing {
                        ProgressView(L10n.text("正在准备差异视图…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let preparationError {
                        Text(preparationError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(24)
                    } else if document.hunkIDs.isEmpty {
                        ScrollView {
                            if document.containsBinaryNotice {
                                binaryNotice
                            } else {
                                Text(text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(24)
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    } else {
                        DiffTableView(
                            document: document,
                            documentID: documentID,
                            sideBySide: sideBySide,
                            columnWidth: width,
                            unifiedWidth: measuredUnifiedWidth,
                            availableWidth: availableWidth,
                            scrollRequest: scrollRequest
                        )
                    }
                }
                .onChange(of: sideBySide) { _, _ in
                    if !document.hunkIDs.isEmpty {
                        scrollRequest = DiffScrollRequest(lineID: document.hunkIDs[hunkIndex])
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .modifier(WorkspacePanel())
            .padding(12)
            Divider()
            HStack {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 850, idealWidth: 1050, minHeight: 540, idealHeight: 680)
        .modifier(WorkspaceBackground())
        .task(id: text) { await updateDocument() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(WorkspaceStyle.accent)
                .frame(width: 40, height: 40)
                .background(WorkspaceStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                WorkspacePathLabel(path: title)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.text("复制路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(title, forType: .string)
            }
            if !document.containsBinaryNotice {
                Button(L10n.text("复制差异")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(isPreparing)
            }
            if let fileURL {
                Button(L10n.text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
        .padding(16)
        .background(.bar)
    }

    /// 二进制文件展示能力说明；原始输出仍可展开，包含 SVN 返回的属性变更。
    private var binaryNotice: some View {
        let isWord = ["doc", "docx", "docm", "dot", "dotx", "dotm"]
            .contains((title as NSString).pathExtension.lowercased())
        return VStack(alignment: .leading, spacing: 24) {
            ContentUnavailableView {
                Label(isWord ? L10n.text("暂不支持 Word 内容对比") : L10n.text("暂不支持此文件的内容对比"),
                      systemImage: "doc.richtext")
            } description: {
                Text(isWord
                     ? L10n.text("此 Word 文档以二进制形式存储，当前查看器无法展示正文、表格或格式的变化。这不代表两个版本内容相同。")
                     : L10n.text("此文件以二进制形式存储，当前查看器无法展示其内容变化。这不代表两个版本内容相同。"))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("原版本：%@", oldLabel))
                Text(L10n.text("新版本：%@", newLabel))
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup(L10n.text("技术详情（SVN 原始输出及属性变更）")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("复制诊断信息")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .padding(.top, 12)
            }
            .font(.caption)
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    /// 清空旧结果后准备新内容；取消的请求不能回填到已切换或关闭的视图。
    @MainActor
    private func updateDocument() async {
        isPreparing = true
        preparationError = nil
        document = UnifiedDiff("")
        measuredColumnWidth = 0
        measuredUnifiedWidth = 0
        scrollRequest = nil
        hunkIndex = 0
        do {
            let presentation = try await DiffPresentation.prepare(text: text)
            try Task.checkCancellation()
            document = presentation.document
            measuredColumnWidth = presentation.columnWidth
            measuredUnifiedWidth = presentation.unifiedWidth
            documentID = UUID()
            isPreparing = false
        } catch {
            guard !Task.isCancelled else { return }
            preparationError = error.localizedDescription
            isPreparing = false
        }
    }

}
