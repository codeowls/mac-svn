import AppKit
import SwiftUI

struct CheckoutView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var repository = ""
    @ViewState private var parent: URL? = nil
    @ViewState private var folderName = ""

    private var isValid: Bool {
        !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parent != nil && !folderName.isEmpty
            && !folderName.contains("/") && ![".", ".."].contains(folderName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("检出 SVN 仓库").font(.title2.bold())
            TextField("仓库 URL，例如 https://svn.example.com/project/trunk", text: $repository)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(parent?.path ?? "请选择保存位置")
                    .font(.caption).lineLimit(2)
                Spacer()
                Button("选择文件夹…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK { parent = panel.url }
                }
            }
            TextField("新建工作副本目录名称", text: $folderName)
                .textFieldStyle(.roundedBorder)
            Text("目标目录必须尚不存在。首版不检出 externals；私有仓库需要先在终端完成 SVN 认证。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("开始检出") {
                    guard let parent else { return }
                    model.checkout(
                        repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                        destination: parent.appendingPathComponent(folderName, isDirectory: true)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}
