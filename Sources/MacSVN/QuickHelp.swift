import AppKit
import SwiftUI

extension View {
    func quickHelp(_ text: String) -> some View {
        modifier(QuickHelpModifier(text: text))
    }
}

private struct QuickHelpModifier: ViewModifier {
    let text: String
    @ViewState private var hovering = false
    @ViewState private var showing = false

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .background(HelpAnchor(text: text, showing: showing))
            .onHover { entered in
                hovering = entered
                if !entered { showing = false }
            }
            .task(id: hovering) {
                guard hovering else { return }
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                showing = true
            }
            .simultaneousGesture(TapGesture().onEnded {
                hovering = false
                showing = false
            })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                hovering = false
                showing = false
            }
            .onDisappear {
                hovering = false
                showing = false
            }
    }
}

private struct HelpAnchor: NSViewRepresentable {
    let text: String
    let showing: Bool

    func makeNSView(context: Context) -> HelpAnchorView {
        HelpAnchorView()
    }

    func updateNSView(_ view: HelpAnchorView, context: Context) {
        if showing { view.show(text) }
        else { view.hide() }
    }

    static func dismantleNSView(_ view: HelpAnchorView, coordinator: ()) {
        view.hide()
    }
}

/// 提示窗不获取焦点、不接收鼠标事件，避免妨碍工具栏点击；位置限制在当前屏幕内。
private final class HelpAnchorView: NSView {
    private var panel: NSPanel?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hide()
        super.viewWillMove(toWindow: newWindow)
    }

    func show(_ text: String) {
        guard panel == nil, let window, window.isKeyWindow, let screen = window.screen else { return }
        let content = NSHostingView(rootView:
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        )
        let size = content.fittingSize
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let origin = NSPoint(
            x: min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width),
            y: max(anchor.minY - size.height - 8, visible.minY)
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.appearance = effectiveAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}
