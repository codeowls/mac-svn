import Foundation

public struct DiffLine: Identifiable, Sendable {
    public enum Kind: Sendable {
        case metadata, hunk, context, addition, deletion
    }

    public let id: Int
    public let text: String
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
}

public struct DiffRow: Identifiable, Sendable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?
    public let spanning: DiffLine?
}

/// 只在文本 hunk 的行数范围内识别增删行，避免将文件头、属性或二进制提示当作代码。
public struct UnifiedDiff: Sendable {
    public let lines: [DiffLine]
    public let splitRows: [DiffRow]
    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
    public var hunkIDs: [Int] { lines.filter { $0.kind == .hunk }.map(\.id) }

    /// 只识别 SVN 的二进制诊断，避免把正文中的同名文字误判为不支持对比。
    public var containsBinaryNotice: Bool {
        lines.contains {
            $0.kind == .metadata && $0.text == "Cannot display: file marked as a binary type."
        }
    }

    public init(_ text: String) {
        let header = /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
        var oldNumber = 0
        var newNumber = 0
        var oldRemaining = 0
        var newRemaining = 0
        var parsed: [DiffLine] = []
        var source = text.components(separatedBy: "\n")
        if source.last == "" { source.removeLast() }
        for (index, raw) in source.enumerated() {
            var kind: DiffLine.Kind = .metadata
            var old: Int?
            var new: Int?
            if let match = raw.prefixMatch(of: header) {
                oldNumber = Int(match.1) ?? 0
                newNumber = Int(match.3) ?? 0
                oldRemaining = match.2.flatMap { Int($0) } ?? 1
                newRemaining = match.4.flatMap { Int($0) } ?? 1
                kind = .hunk
            } else if raw.hasPrefix("-") && oldRemaining > 0 {
                kind = .deletion
                old = oldNumber
                oldNumber += 1
                oldRemaining -= 1
            } else if raw.hasPrefix("+") && newRemaining > 0 {
                kind = .addition
                new = newNumber
                newNumber += 1
                newRemaining -= 1
            } else if raw.hasPrefix(" ") && oldRemaining > 0 && newRemaining > 0 {
                kind = .context
                old = oldNumber
                new = newNumber
                oldNumber += 1
                newNumber += 1
                oldRemaining -= 1
                newRemaining -= 1
            } else if !raw.hasPrefix("\\") {
                oldRemaining = 0
                newRemaining = 0
            }
            parsed.append(DiffLine(id: index, text: raw, kind: kind, oldNumber: old, newNumber: new))
        }
        lines = parsed
        splitRows = Self.pairLines(parsed)
    }

    /// 连续删除与新增按位置对齐，共用同一滚动区域，保留未配对行及 SVN 原始说明。
    private static func pairLines(_ lines: [DiffLine]) -> [DiffRow] {
        var rows: [DiffRow] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .addition || line.kind == .deletion {
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while index < lines.count {
                    let current = lines[index]
                    guard current.kind == .addition || current.kind == .deletion else { break }
                    if current.kind == .deletion { removed.append(current) }
                    else { added.append(current) }
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    let left = offset < removed.count ? removed[offset] : nil
                    let right = offset < added.count ? added[offset] : nil
                    rows.append(DiffRow(id: left?.id ?? right!.id, left: left, right: right, spanning: nil))
                }
            } else {
                let isContext = line.kind == .context
                rows.append(DiffRow(
                    id: line.id,
                    left: isContext ? line : nil,
                    right: isContext ? line : nil,
                    spanning: isContext ? nil : line
                ))
                index += 1
            }
        }
        return rows
    }
}
