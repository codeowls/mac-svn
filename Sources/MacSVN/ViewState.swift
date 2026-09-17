import AppKit
import SwiftUI

// Explicitly name the property-wrapper type: macOS 27's SDK also exports a State macro,
// whose plugin is not shipped with the standalone Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

/// 绑定实际承载视图的窗口；后台或辅助功能触发按钮时，App 的 keyWindow 可能为空。
struct ViewWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange?(window)
            }
        }
    }
}
