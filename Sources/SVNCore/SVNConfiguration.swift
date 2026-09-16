import Foundation

public enum SVNConfiguration {
    // 常见临时文件加上 macOS / IDEA 项目文件；只有用户启用自定义规则后才生效。
    public static let suggestedGlobalIgnores = """
    *.o *.lo *.la *.al .libs *.so *.so.[0-9]* *.a
    *.pyc *.pyo __pycache__ *.rej *~ #*# .#* .*.swp
    .DS_Store .idea *.iml
    """

    /// SVN 全局忽略使用空白分隔的文件名通配符；保留顺序，不把 # 当作注释。
    public static func normalizeIgnorePatterns(_ text: String) throws -> String {
        guard !text.contains("\0") else {
            throw SVNError("忽略规则不能包含空字符。")
        }
        var seen: Set<String> = []
        return text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { seen.insert($0).inserted }
            .joined(separator: " ")
    }

    /// 文件选择器和手动输入共用校验，支持展开用户输入的 ~ 路径。
    public static func executableURL(for path: String) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !expanded.contains("\0"), expanded.hasPrefix("/"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: expanded) else {
            throw SVNError("请选择有效的 SVN 可执行文件，例如 /opt/homebrew/bin/svn。")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
