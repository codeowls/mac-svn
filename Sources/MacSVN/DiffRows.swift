import SwiftUI
import SVNCore

/// 原生表格中的差异行仅接收不可变数据，保留统一／并排视图的配色和行号。
@MainActor
enum DiffRows {
    private static func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 10)
            .background(Color.primary.opacity(0.035))
    }

    private static func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        default: .clear
        }
    }

    static func unifiedRow(_ line: DiffLine) -> some View {
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

    static func splitRow(_ row: DiffRow, width: CGFloat) -> some View {
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

    private static func splitCell(_ line: DiffLine?, old: Bool, width: CGFloat) -> some View {
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
