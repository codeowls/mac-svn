import AppKit
import SwiftUI
import SVNCore

struct MergeToolSettingsView: View {
    @ViewState private var selection = UserDefaults.standard.string(forKey: "externalMergeTool") ?? ""
    @ViewState private var path = UserDefaults.standard.string(forKey: "externalMergeExecutable") ?? ""
    @ViewState private var feedback = ""
    @ViewState private var isError = false

    private var tool: ExternalMergeTool? { ExternalMergeTool(rawValue: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("冲突合并工具", selection: $selection) {
                Text("不使用外部合并工具").tag("")
                ForEach(ExternalMergeTool.allCases) { tool in
                    Text(tool.title).tag(tool.rawValue)
                }
            }
            .onChange(of: selection) { _, _ in
                path = tool?.discoverExecutable()?.path ?? ""
                feedback = tool == nil ? "" : (path.isEmpty
                    ? "常见目录未检测到该工具，请安装或手动选择位置。"
                    : "已找到安装位置，保存后生效。")
                isError = tool != nil && path.isEmpty
            }
            TextField("应用或命令行工具的完整路径", text: $path)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("外部合并工具路径")
                .disabled(tool == nil)
            HStack {
                Button("选择应用…") { chooseApplication() }
                Button("重新检测") {
                    if let executable = tool?.discoverExecutable() {
                        path = executable.path
                        feedback = "已找到安装位置，保存后生效。"
                        isError = false
                    } else {
                        feedback = "常见目录未检测到该工具，请安装或手动选择位置。"
                        isError = true
                    }
                }
            }
            .disabled(tool == nil)
            Text("工具需另行安装。FileMerge 随完整 Xcode 提供；商业工具的三方合并功能可能需要相应许可。")
                .font(.caption).foregroundStyle(.secondary)
            Text("会传入基准、本地、传入版本，并将当前工作文件指定为保存结果。工具退出不代表冲突已解决，仍需回到 Mac SVN 检查最终内容并确认。")
                .font(.callout).foregroundStyle(.secondary)
            Text("此设置只用于处理内容冲突，日常差异查看仍使用内置视图。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Text(feedback).font(.caption).foregroundStyle(isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("保存合并工具") { save() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择 \(tool?.title ?? "合并工具") 应用"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            feedback = ""
        }
    }

    /// Persist only validated installation paths; saving does not launch the tool.
    private func save() {
        do {
            guard selection.isEmpty || tool != nil else {
                throw SVNError("保存的工具类型无法识别，请重新选择合并工具。")
            }
            if let tool {
                let executable = try tool.executableURL(for: path)
                UserDefaults.standard.set(executable.path, forKey: "externalMergeExecutable")
                UserDefaults.standard.set(tool.rawValue, forKey: "externalMergeTool")
                path = executable.path
            } else {
                UserDefaults.standard.removeObject(forKey: "externalMergeTool")
                UserDefaults.standard.removeObject(forKey: "externalMergeExecutable")
            }
            feedback = "合并工具设置已保存。"
            isError = false
        } catch {
            feedback = error.localizedDescription
            isError = true
        }
    }
}
