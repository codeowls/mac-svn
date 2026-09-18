import SwiftUI

/// 窗口与弹窗共用语义色，随系统外观变化。
enum WorkspaceStyle {
    static let accent = Color.blue
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let input = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.45)
}

struct WorkspaceBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(WorkspaceStyle.accent)
            .background {
                WorkspaceStyle.canvas
                    .overlay(Color.primary.opacity(0.05))
            }
    }
}

/// 辅助窗口保持一致的标题层级，危险操作可单独指定警示色。
struct WorkspaceHeading: View {
    let title: String
    let icon: String
    var color: Color = WorkspaceStyle.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
        }
    }
}

struct WorkspaceBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct WorkspacePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(WorkspaceStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// 文件名优先阅读，目录保持次级显示；完整原始路径仍通过悬停可见。
struct WorkspacePathLabel: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((path as NSString).lastPathComponent)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                Text(directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(path)
    }
}

/// 侧栏入口保留轻量行样式，同时提供明确的悬停和按下反馈。
struct SidebarActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : (isHovered ? 0.05 : 0)))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 && isEnabled }
    }
}
