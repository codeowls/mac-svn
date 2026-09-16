import AppKit
import SwiftUI
import SVNCore

struct CheckoutView: View {
    @ObservedObject var model: AppModel
    @StateObject private var browser = RepositoryBrowserModel()
    @Environment(\.dismiss) private var dismiss
    @ViewState private var parent: URL?
    @ViewState private var folderName = ""
    @ViewState private var suggestedFolderName = ""

    private var destination: URL? {
        parent?.appendingPathComponent(folderName, isDirectory: true)
    }

    private var checkoutUnavailableReason: String? {
        if model.isBusy { return "请等待当前操作完成。" }
        if browser.isLoading { return "正在浏览仓库，请稍候。" }
        if browser.checkoutURL.isEmpty { return "请输入仓库或分支地址。" }
        if parent == nil { return "请选择本地保存位置。" }
        if folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写新建文件夹名称，检出时会自动创建。"
        }
        if folderName.contains("/") || folderName.contains("\0") || [".", ".."].contains(folderName) {
            return "请输入单个文件夹名称，不能包含 /，也不能使用 . 或 ..。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.to.line")
                    .font(.title2).frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("检出远端分支").font(.title2.bold())
                    Text("浏览仓库找到分支，或直接粘贴分支 URL。")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("仓库或分支地址").font(.headline)
                HStack {
                    TextField("https://svn.example.com/project", text: $browser.address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { withClient { browser.browse(using: $0) } }
                        .disabled(browser.isLoading)
                    Button("浏览仓库") { withClient { browser.browse(using: $0) } }
                        .disabled(browser.checkoutURL.isEmpty || browser.isLoading)
                }
                repositoryList
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("本地保存位置（父文件夹）").font(.headline)
                HStack {
                    Label(parent?.path ?? "选择存放工作副本的文件夹", systemImage: "folder")
                        .foregroundStyle(parent == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle).help(parent?.path ?? "")
                    Spacer()
                    Button("选择文件夹…") { chooseParent() }
                }
                Text("新建工作副本文件夹（必填）").font(.subheadline)
                TextField("例如 my-project，检出时自动创建", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                if let destination, checkoutUnavailableReason == nil {
                    Text("检出到：\(destination.path)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(destination.path)
                }
                if let reason = checkoutUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("递归检出当前地址下的全部子目录和文件，不包含 externals（外部引用）。\n私有仓库复用本机 SVN 已缓存的认证；目标工作副本文件夹须尚不存在。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("检出后自动打开工作副本").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("开始检出") {
                    guard let destination else { return }
                    model.checkout(repository: browser.checkoutURL, destination: destination)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkoutUnavailableReason != nil)
            }
        }
        .padding(28)
        .frame(width: 660)
        .onChange(of: browser.address) { _, _ in
            browser.addressChanged()
            suggestFolderName()
        }
        .onDisappear { browser.cancel() }
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withClient { browser.goBack(using: $0) } } label: {
                    Label("返回上一级", systemImage: "chevron.left")
                }
                .disabled(!browser.canGoBack)
                Spacer()
                if browser.isLoading {
                    ProgressView().controlSize(.small)
                    Text("连接仓库…").font(.caption)
                } else if let location = browser.location {
                    Text("当前目录 · r\(location.revision)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                if let error = browser.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else if browser.location == nil {
                    Text("输入仓库地址后点击“浏览仓库”。\n进入 trunk、branches 或其他目录，即可检出当前分支。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if browser.entries.isEmpty {
                    Text("这是一个空目录，仍可检出到本机。")
                        .foregroundStyle(.secondary).padding(20)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(browser.entries) { entry in
                            Button { withClient { browser.enter(entry, using: $0) } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                        .foregroundStyle(.secondary)
                                    Text(entry.name).lineLimit(1)
                                    Spacer()
                                    Text("r\(entry.revision)").font(.caption).foregroundStyle(.secondary)
                                    if entry.isDirectory { Image(systemName: "chevron.right").font(.caption2) }
                                }
                                .padding(10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!entry.isDirectory || browser.isLoading)
                            .accessibilityLabel(entry.isDirectory ? "进入 \(entry.name)" : entry.name)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(height: 180)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private func withClient(_ action: (SVNClient) -> Void) {
        do { action(try model.client()) }
        catch { browser.report(error) }
    }

    /// 跟随仓库地址建议目录名，保留用户手动填写的名称。
    private func suggestFolderName() {
        let name = URL(string: browser.checkoutURL)?.lastPathComponent ?? ""
        if folderName.isEmpty || folderName == suggestedFolderName {
            folderName = name == "/" ? "" : name
        }
        suggestedFolderName = name
    }

    /// 允许在系统选择器中新建父文件夹；工作副本子目录由 SVN 创建。
    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "选择工作副本的保存位置"
        panel.prompt = "选择"
        panel.message = "选择或新建父文件夹；工作副本将在其中按填写的名称自动创建。"
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        if panel.runModal() == .OK { parent = panel.url }
    }
}
