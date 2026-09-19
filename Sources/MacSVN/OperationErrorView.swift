import SVNCore
import AppKit
import SwiftUI

/// 将完整错误限制在滚动区域内，避免长日志把关闭按钮挤出屏幕。
struct OperationErrorView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("操作未完成"))
                        .font(.headline)
                    Text(L10n.text("请查看下方错误详情。"))
                        .foregroundStyle(.secondary)
                }
            }

            OperationOutputView(
                text: message,
                followsOutput: false,
                accessibilityLabel: L10n.text("完整错误详情")
            )
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button(L10n.text("复制完整详情")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                Spacer()
                Button(L10n.text("关闭"), action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 440)
        .onExitCommand(perform: onClose)
    }
}
