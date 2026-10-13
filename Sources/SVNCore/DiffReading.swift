import Foundation

public struct DiffSearchMatch: Equatable, Sendable {
    public let lineID: Int
    public let range: NSRange
}

/// 只为真实增删正文计算词级变化，元数据和属性说明不当作代码处理。
public struct DiffReading: Sendable {
    public let wordRanges: [Int: [NSRange]]

    private struct Token {
        let text: String
        let range: NSRange
    }

    public init(document: UnifiedDiff) {
        self.init(document: document, checkCancellation: {})
    }

    public init(document: UnifiedDiff, checkCancellation: () throws -> Void) rethrows {
        var ranges: [Int: [NSRange]] = [:]
        for (index, row) in document.splitRows.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            if let left = row.left, let right = row.right,
               left.kind == .deletion, right.kind == .addition {
                let old = try Self.tokens(left.text, checkCancellation: checkCancellation)
                let new = try Self.tokens(right.text, checkCancellation: checkCancellation)
                let difference = new.map(\.text).difference(from: old.map(\.text))
                for change in difference {
                    try checkCancellation()
                    switch change {
                    case let .remove(offset, _, _):
                        ranges[left.id, default: []].append(old[offset].range)
                    case let .insert(offset, _, _):
                        ranges[right.id, default: []].append(new[offset].range)
                    }
                }
            } else {
                for line in [row.left, row.right].compactMap({ $0 })
                    where line.kind == .deletion || line.kind == .addition {
                    let count = line.text.utf16.count - 1
                    if count > 0 {
                        ranges[line.id] = [NSRange(location: 1, length: count)]
                    }
                }
            }
        }
        wordRanges = ranges.mapValues { $0.sorted { $0.location < $1.location } }
    }

    /// Foundation 的 UTF-16 范围直接对应显示文本，支持中文、表情和同一行多次匹配。
    public static func search(document: UnifiedDiff, query: String) -> [DiffSearchMatch] {
        search(document: document, query: query, checkCancellation: {})
    }

    public static func search(
        document: UnifiedDiff, query: String, checkCancellation: () throws -> Void
    ) rethrows -> [DiffSearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DiffSearchMatch] = []
        for (index, line) in document.lines.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let text = line.text as NSString
            let start = line.oldNumber != nil || line.newNumber != nil ? 1 : 0
            var remaining = NSRange(location: start, length: text.length - start)
            while remaining.length > 0 {
                try checkCancellation()
                let range = text.range(of: query, options: .caseInsensitive, range: remaining)
                guard range.location != NSNotFound else { break }
                matches.append(DiffSearchMatch(lineID: line.id, range: range))
                let next = NSMaxRange(range)
                remaining = NSRange(location: next, length: text.length - next)
            }
        }
        return matches
    }

    /// ASCII 标识符按词分组，非 ASCII 字符按完整字素处理，不拆开表情或组合字符。
    private static func tokens(_ line: String, checkCancellation: () throws -> Void) rethrows -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var start = 1
        var offset = 1
        var previousKind: Int?
        for (index, character) in line.dropFirst().enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let kind: Int
            if character.isASCII && (character.isLetter || character.isNumber || character == "_") {
                kind = 0
            } else if character.isWhitespace {
                kind = 1
            } else {
                kind = 2
            }
            if !text.isEmpty && (kind != previousKind || kind == 2) {
                tokens.append(Token(text: text, range: NSRange(location: start, length: offset - start)))
                text = ""
                start = offset
            }
            text.append(character)
            offset += String(character).utf16.count
            previousKind = kind
        }
        if !text.isEmpty {
            tokens.append(Token(text: text, range: NSRange(location: start, length: offset - start)))
        }
        return tokens
    }
}
