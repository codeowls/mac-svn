import SVNCore
import AppKit
import SwiftUI

/// 大量日志使用原生滚动文本视图；追加内容不反复参与 SwiftUI 的整段文本尺寸计算。
struct OperationOutputView: NSViewRepresentable {
    let text: String
    let followsOutput: Bool
    var accessibilityLabel = L10n.text("完整操作输出")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let previous = context.coordinator.text
        let changed = previous != text
        let content = text as NSString
        let oldLength = (previous as NSString).length
        // 使用 UTF-16 偏移对接 NSTextStorage，中文和 emoji 不会被按 Swift 字符数截断。
        if changed, text.hasPrefix(previous) {
            view.textStorage?.append(NSAttributedString(
                string: content.substring(from: oldLength),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: NSColor.labelColor]
            ))
        } else if changed {
            view.string = text
        }
        context.coordinator.text = text
        if followsOutput && (changed || !context.coordinator.followedOutput) {
            view.scrollRangeToVisible(NSRange(location: content.length, length: 0))
        }
        context.coordinator.followedOutput = followsOutput
    }

    final class Coordinator {
        var text = ""
        var followedOutput = false
    }
}
