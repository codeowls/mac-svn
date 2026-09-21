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
    public let additions: Int
    public let deletions: Int
    public let hunkIDs: [Int]
    public let containsBinaryNotice: Bool

    public init(_ text: String) {
        self.init(text, checkCancellation: {})
    }

    /// 解析与配对阶段定期检查取消；同步调用者仍可使用不抛错的初始化方法。
    public init(_ text: String, checkCancellation: () throws -> Void) rethrows {
        try checkCancellation()
        let header = /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
        var oldNumber = 0
        var newNumber = 0
        var oldRemaining = 0
        var newRemaining = 0
        var parsed: [DiffLine] = []
        var additions = 0
        var deletions = 0
        var hunkIDs: [Int] = []
        var containsBinaryNotice = false
        var source = text.components(separatedBy: "\n")
        if source.last == "" { source.removeLast() }
        parsed.reserveCapacity(source.count)
        for (index, raw) in source.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            var kind: DiffLine.Kind = .metadata
            var old: Int?
            var new: Int?
            if raw.hasPrefix("@@ "), let match = raw.prefixMatch(of: header) {
                oldNumber = Int(match.1) ?? 0
                newNumber = Int(match.3) ?? 0
                oldRemaining = match.2.flatMap { Int($0) } ?? 1
                newRemaining = match.4.flatMap { Int($0) } ?? 1
                kind = .hunk
                hunkIDs.append(index)
            } else if raw.hasPrefix("-") && oldRemaining > 0 {
                kind = .deletion
                deletions += 1
                old = oldNumber
                oldNumber += 1
                oldRemaining -= 1
            } else if raw.hasPrefix("+") && newRemaining > 0 {
                kind = .addition
                additions += 1
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
            // 只识别元数据中的 SVN 诊断，正文中的同名文字不能判为二进制。
            if kind == .metadata && raw == "Cannot display: file marked as a binary type." {
                containsBinaryNotice = true
            }
            parsed.append(DiffLine(id: index, text: raw, kind: kind, oldNumber: old, newNumber: new))
        }
        lines = parsed
        splitRows = try Self.pairLines(parsed, checkCancellation: checkCancellation)
        self.additions = additions
        self.deletions = deletions
        self.hunkIDs = hunkIDs
        self.containsBinaryNotice = containsBinaryNotice
    }

    /// 连续删除与新增按位置对齐，共用同一滚动区域，保留未配对行及 SVN 原始说明。
    private static func pairLines(
        _ lines: [DiffLine], checkCancellation: () throws -> Void
    ) rethrows -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(lines.count)
        var index = 0
        while index < lines.count {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let line = lines[index]
            if line.kind == .addition || line.kind == .deletion {
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while index < lines.count {
                    if index.isMultiple(of: 256) { try checkCancellation() }
                    let current = lines[index]
                    guard current.kind == .addition || current.kind == .deletion else { break }
                    if current.kind == .deletion { removed.append(current) }
                    else { added.append(current) }
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    if offset.isMultiple(of: 256) { try checkCancellation() }
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
