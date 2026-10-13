import AppKit
import SwiftUI
import SVNCore

struct DiffScrollRequest: Equatable {
    let id = UUID()
    let lineID: Int
    var match: DiffSearchMatch? = nil
}

private struct DiffCellIdentity: Hashable {
    let documentID: UUID
    let rowID: Int
    let sideBySide: Bool
    let highlights: UUID
}

/// 原生表格按可见行复用视图，滚动和辅助功能不经过 SwiftUI 的 LazyVStack 行索引。
struct DiffTableView: NSViewRepresentable {
    let document: UnifiedDiff
    let documentID: UUID
    let sideBySide: Bool
    let columnWidth: CGFloat
    let unifiedWidth: CGFloat
    let availableWidth: CGFloat
    let scrollRequest: DiffScrollRequest?
    var wordRanges: [Int: [NSRange]] = [:]
    var searchMatches: [DiffSearchMatch] = []
    var showWords = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 25
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = []
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let table = scroll.documentView as! NSTableView
        context.coordinator.update(self, table: table, scroll: scroll)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var value: DiffTableView?
        private var rowIndices: [Int: Int] = [:]
        private var lastScrollID: UUID?
        private var searchRanges: [Int: [NSRange]] = [:]
        private var highlightIdentity = UUID()

        /// 仅内容或布局变化时重建行映射；窗口缩放只更新可见行宽度。
        func update(_ next: DiffTableView, table: NSTableView, scroll: NSScrollView) {
            let contentChanged = value?.documentID != next.documentID || value?.sideBySide != next.sideBySide
            let widthChanged = value?.columnWidth != next.columnWidth || value?.availableWidth != next.availableWidth
            let highlightsChanged = value?.showWords != next.showWords || value?.searchMatches != next.searchMatches
            if highlightsChanged {
                highlightIdentity = UUID()
            }
            if value?.searchMatches != next.searchMatches {
                searchRanges = Dictionary(grouping: next.searchMatches, by: \.lineID).mapValues { $0.map(\.range) }
            }
            value = next
            let width = next.sideBySide
                ? next.columnWidth * 2 + 1
                : max(next.availableWidth, next.unifiedWidth)
            table.tableColumns[0].width = width
            if contentChanged {
                rowIndices = [:]
                if next.sideBySide {
                    for (index, row) in next.document.splitRows.enumerated() {
                        for line in [row.left, row.right, row.spanning].compactMap({ $0 }) {
                            rowIndices[line.id] = index
                        }
                    }
                } else {
                    rowIndices = Dictionary(uniqueKeysWithValues: next.document.lines.enumerated().map { ($0.element.id, $0.offset) })
                }
                table.reloadData()
            } else if widthChanged || highlightsChanged {
                let visible = table.rows(in: scroll.contentView.bounds)
                if visible.length > 0 {
                    table.reloadData(
                        forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
            if let request = next.scrollRequest, request.id != lastScrollID,
               let index = rowIndices[request.lineID] {
                lastScrollID = request.id
                // 左上角定位，长行不会因变更跳转而遮住左侧行号。
                let y = min(table.rect(ofRow: index).minY, max(0, table.bounds.height - scroll.contentSize.height))
                let x = horizontalPosition(for: request, value: next, scroll: scroll, table: table)
                scroll.contentView.scroll(to: NSPoint(x: x, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if contentChanged && next.scrollRequest == nil {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            guard let value else { return 0 }
            return value.sideBySide ? value.document.splitRows.count : value.document.lines.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let value else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("diff-row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DiffCell ?? DiffCell()
            cell.identifier = identifier
            let content: AnyView
            if value.sideBySide {
                content = AnyView(DiffRows.splitRow(
                    value.document.splitRows[row], width: value.columnWidth,
                    words: value.showWords ? value.wordRanges : [:], matches: searchRanges
                ))
            } else {
                let line = value.document.lines[row]
                content = AnyView(DiffRows.unifiedRow(
                    line, words: value.showWords ? value.wordRanges[line.id] ?? [] : [],
                    matches: searchRanges[line.id] ?? []
                ))
            }
            cell.host.rootView = AnyView(content
                // 原生可选择文本按当前行重建，避免复用宿主时残留上一行的文本或样式。
                .id(DiffCellIdentity(
                    documentID: value.documentID,
                    rowID: value.sideBySide ? value.document.splitRows[row].id : value.document.lines[row].id,
                    sideBySide: value.sideBySide, highlights: highlightIdentity
                ))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            return cell
        }

        /// 搜索长行时同时露出目标列；普通变更导航仍从行号位置开始。
        private func horizontalPosition(
            for request: DiffScrollRequest, value: DiffTableView, scroll: NSScrollView, table: NSTableView
        ) -> CGFloat {
            guard let match = request.match,
                  let line = value.document.lines.first(where: { $0.id == match.lineID }) else { return 0 }
            var text = line.text as NSString
            var offset = match.range.location
            var inset: CGFloat = 120
            if value.sideBySide {
                if line.oldNumber != nil || line.newNumber != nil {
                    text = String(line.text.dropFirst()) as NSString
                    offset = max(0, offset - 1)
                    inset = line.kind == .addition ? value.columnWidth + 72 : 72
                } else {
                    inset = 12
                }
            }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let target = (text.substring(to: offset) as NSString).size(withAttributes: [.font: font]).width + inset
            let desired = max(0, target - scroll.contentSize.width / 3)
            return min(desired, max(0, table.bounds.width - scroll.contentSize.width))
        }
    }

    final class DiffCell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))

        init() {
            super.init(frame: .zero)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { super.init(coder: coder) }
    }
}
