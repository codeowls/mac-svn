import SwiftUI
import Foundation
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

    static func unifiedRow(_ line: DiffLine, words: [NSRange] = [], matches: [NSRange] = []) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            highlightedText(line, words: words, matches: matches)
                .foregroundStyle(line.kind == .metadata || line.kind == .hunk ? .secondary : .primary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 4)
        .background(background(line))
    }

    static func splitRow(
        _ row: DiffRow, width: CGFloat, words: [Int: [NSRange]] = [:], matches: [Int: [NSRange]] = [:]
    ) -> some View {
        Group {
            if let line = row.spanning {
                highlightedText(line, words: [], matches: matches[line.id] ?? [])
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(minWidth: width * 2 + 1, alignment: .leading)
                    .background(background(line))
            } else {
                HStack(spacing: 0) {
                    splitCell(row.left, old: true, width: width, words: words, matches: matches)
                    Rectangle().fill(.separator).frame(width: 1)
                    splitCell(row.right, old: false, width: width, words: words, matches: matches)
                }
            }
        }
    }

    private static func splitCell(
        _ line: DiffLine?, old: Bool, width: CGFloat, words: [Int: [NSRange]], matches: [Int: [NSRange]]
    ) -> some View {
        HStack(spacing: 0) {
            number(old ? line?.oldNumber : line?.newNumber)
            Group {
                if let line {
                    highlightedText(line, words: words[line.id] ?? [], matches: matches[line.id] ?? [], dropPrefix: true)
                } else {
                    Text(" ")
                }
            }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .background(line.map(background) ?? Color.secondary.opacity(0.04))
    }

    /// 拼接同一个 Text，保留整行文本选择；搜索和词级变化使用不同颜色和下划线。
    private static func highlightedText(
        _ line: DiffLine, words: [NSRange], matches: [NSRange], dropPrefix: Bool = false
    ) -> Text {
        let text = line.text as NSString
        let start = dropPrefix ? min(1, text.length) : 0
        let bounds = Set([start, text.length] + (words + matches).flatMap { [$0.location, NSMaxRange($0)] })
            .filter { $0 >= start && $0 <= text.length }.sorted()
        var result = Text("")
        for (lower, upper) in zip(bounds, bounds.dropFirst()) where lower < upper {
            let range = NSRange(location: lower, length: upper - lower)
            var part = Text(text.substring(with: range))
            if matches.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                part = part.bold().underline().foregroundColor(.orange)
            } else if words.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                part = part.bold().underline().foregroundColor(line.kind == .deletion ? .red : .green)
            }
            result = result + part
        }
        return text.length == start ? Text(" ") : result
    }
}
