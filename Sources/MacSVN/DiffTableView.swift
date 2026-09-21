import AppKit
import SwiftUI
import SVNCore

struct DiffScrollRequest: Equatable {
    let id = UUID()
    let lineID: Int
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

        /// 仅内容或布局变化时重建行映射；窗口缩放只更新可见行宽度。
        func update(_ next: DiffTableView, table: NSTableView, scroll: NSScrollView) {
            let contentChanged = value?.documentID != next.documentID || value?.sideBySide != next.sideBySide
            let widthChanged = value?.columnWidth != next.columnWidth || value?.availableWidth != next.availableWidth
            value = next
            let width = next.sideBySide
                ? next.columnWidth * 2 + 1
                : max(next.availableWidth, next.unifiedWidth)
            table.tableColumns[0].width = width
            if contentChanged {
                let ids = next.sideBySide ? next.document.splitRows.map(\.id) : next.document.lines.map(\.id)
                rowIndices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                table.reloadData()
            } else if widthChanged {
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
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
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
                content = AnyView(DiffRows.splitRow(value.document.splitRows[row], width: value.columnWidth))
            } else {
                content = AnyView(DiffRows.unifiedRow(value.document.lines[row]))
            }
            cell.host.rootView = AnyView(content
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            return cell
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
