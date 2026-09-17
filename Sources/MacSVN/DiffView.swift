import AppKit
import SwiftUI
import SVNCore

struct DiffView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DiffContentView(
            title: model.focusedPath ?? "文件差异",
            subtitle: model.entries.first { $0.path == model.focusedPath }?.label ?? "文件差异",
            text: model.diffText,
            oldLabel: "原版本 · BASE",
            newLabel: "本地工作副本",
            footer: "对比本地基准版本与当前内容 · 不会修改文件",
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                if !document.hunkIDs.isEmpty {
                    HStack(spacing: 12) {
                        Picker("展示方式", selection: $sideBySide) {
                            Text("统一").tag(false)
                            Text("并排").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .labelsHidden()
                        .accessibilityLabel("展示方式")
                        Text("+\(document.additions)").foregroundStyle(.green)
                        Text("−\(document.deletions)").foregroundStyle(.red)
                        Spacer()
                        Text("\(hunkIndex + 1) / \(document.hunkIDs.count) 处变更")
                            .foregroundStyle(.secondary)
                        Button {
                            hunkIndex -= 1
                            proxy.scrollTo(document.hunkIDs[hunkIndex], anchor: .top)
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(hunkIndex == 0)
                        .help("上一处变更")
                        Button {
                            hunkIndex += 1
                            proxy.scrollTo(document.hunkIDs[hunkIndex], anchor: .top)
                        } label: { Image(systemName: "chevron.down") }
                        .disabled(hunkIndex == document.hunkIDs.count - 1)
                        .help("下一处变更")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    Divider()
                }
                if sideBySide && !document.hunkIDs.isEmpty {
                    HStack {
                        Text(oldLabel).frame(maxWidth: .infinity, alignment: .leading)
                        Text(newLabel).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                }
                GeometryReader { geometry in
                    let width = columnWidth(available: geometry.size.width)
                    if document.hunkIDs.isEmpty {
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
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if sideBySide {
                                    ForEach(document.splitRows) { row in
                                        splitRow(row, width: width)
                                            .id(row.id)
                                    }
                                } else {
                                    ForEach(document.lines) { line in
                                        unifiedRow(line)
                                            .frame(minWidth: geometry.size.width, alignment: .leading)
                                            .id(line.id)
                                    }
                                }
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 8)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                }
                .onChange(of: sideBySide) { _, _ in
                    if let id = document.hunkIDs.first { proxy.scrollTo(id, anchor: .top) }
                    hunkIndex = 0
                }
            }
            Divider()
            HStack {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 850, idealWidth: 1050, minHeight: 540, idealHeight: 680)
        .onAppear { updateDocument() }
        .onChange(of: text) { _, _ in updateDocument() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline).lineLimit(2).textSelection(.enabled)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !document.containsBinaryNotice {
                Button("复制差异") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            if let fileURL {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
        .padding(16)
    }

    /// 二进制文件展示能力说明；原始输出仍可展开，包含 SVN 返回的属性变更。
    private var binaryNotice: some View {
        let isWord = ["doc", "docx", "docm", "dot", "dotx", "dotm"]
            .contains((title as NSString).pathExtension.lowercased())
        return VStack(alignment: .leading, spacing: 24) {
            ContentUnavailableView {
                Label(isWord ? "暂不支持 Word 内容对比" : "暂不支持此文件的内容对比",
                      systemImage: "doc.richtext")
            } description: {
                Text(isWord
                     ? "此 Word 文档以二进制形式存储，当前查看器无法展示正文、表格或格式的变化。这不代表两个版本内容相同。"
                     : "此文件以二进制形式存储，当前查看器无法展示其内容变化。这不代表两个版本内容相同。")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("原版本：\(oldLabel)")
                Text("新版本：\(newLabel)")
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("技术详情（SVN 原始输出及属性变更）") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("复制诊断信息") {
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

    private func updateDocument() {
        document = UnifiedDiff(text)
        hunkIndex = 0
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 10)
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        default: .clear
        }
    }

    private func unifiedRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .metadata || line.kind == .hunk ? .secondary : .primary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 4)
        .background(background(line))
    }

    /// 并排栏使用相同宽度及单一滚动容器，让两个版本始终纵向对齐。
    private func columnWidth(available: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let longest = document.lines.filter { $0.oldNumber != nil || $0.newNumber != nil }
            .map { (String($0.text.dropFirst()) as NSString).size(withAttributes: [.font: font]).width + 100 }
            .max() ?? 0
        return max((available - 1) / 2, longest)
    }

    private func splitRow(_ row: DiffRow, width: CGFloat) -> some View {
        Group {
            if let line = row.spanning {
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(minWidth: width * 2 + 1, alignment: .leading)
                    .background(background(line))
            } else {
                HStack(spacing: 0) {
                    splitCell(row.left, old: true, width: width)
                    Rectangle().fill(.separator).frame(width: 1)
                    splitCell(row.right, old: false, width: width)
                }
            }
        }
    }

    private func splitCell(_ line: DiffLine?, old: Bool, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            number(old ? line?.oldNumber : line?.newNumber)
            Text(line.map { String($0.text.dropFirst()) } ?? " ")
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .background(line.map(background) ?? Color.secondary.opacity(0.04))
    }
}
