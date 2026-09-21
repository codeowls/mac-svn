import AppKit
import SVNCore

/// 每份差异只解析和测量一次，视图缩放、导航与切换展示方式复用同一份结果。
struct DiffPresentation: Sendable {
    let document: UnifiedDiff
    let columnWidth: CGFloat
    let unifiedWidth: CGFloat

    init(text: String) throws {
        document = try UnifiedDiff(text, checkCancellation: Task.checkCancellation)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var width: CGFloat = 0
        var unifiedWidth: CGFloat = 0
        for (index, line) in document.lines.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let rawWidth = (line.text as NSString).size(withAttributes: [.font: font]).width
            unifiedWidth = max(unifiedWidth, rawWidth + 152)
            guard line.oldNumber != nil || line.newNumber != nil else {
                width = max(width, (rawWidth + 24) / 2)
                continue
            }
            let content = String(line.text.dropFirst()) as NSString
            width = max(width, content.size(withAttributes: [.font: font]).width + 100)
        }
        try Task.checkCancellation()
        columnWidth = width
        self.unifiedWidth = unifiedWidth
    }

    /// 字体测量和文本解析均离开主线程；视图任务取消时同步取消后台任务。
    static func prepare(text: String) async throws -> DiffPresentation {
        let worker = Task.detached(priority: .userInitiated) {
            try DiffPresentation(text: text)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
