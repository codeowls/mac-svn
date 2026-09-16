import AppKit
import SwiftUI
import SVNCore

struct CheckoutView: View {
    @ObservedObject var model: AppModel
    @StateObject private var browser = RepositoryBrowserModel()
    @Environment(\.dismiss) private var dismiss
    @ViewState private var parent: URL?
    @ViewState private var folderName = ""

    private var isValid: Bool {
        !browser.checkoutURL.isEmpty && parent != nil
            && !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folderName.contains("/") && !folderName.contains("\0")
            && ![".", ".."].contains(folderName)
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
                Text("保存到本机").font(.headline)
                HStack {
                    Label(parent?.path ?? "选择存放工作副本的文件夹", systemImage: "folder")
                        .foregroundStyle(parent == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle).help(parent?.path ?? "")
                    Spacer()
                    Button("选择文件夹…") { chooseParent() }
                }
                TextField("新建文件夹名称，例如 my-project", text: $folderName)
                    .textFieldStyle(.roundedBorder)
            }
            Text("私有仓库复用本机 SVN 已缓存的认证。目标文件夹须尚不存在；不检出 externals。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("检出后自动打开工作副本").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("开始检出") {
                    guard let parent else { return }
                    model.checkout(repository: browser.checkoutURL,
                                   destination: parent.appendingPathComponent(folderName, isDirectory: true))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || model.isBusy || browser.isLoading)
            }
        }
        .padding(28)
        .frame(width: 660)
        .onChange(of: browser.address) { _, _ in browser.addressChanged() }
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

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "选择工作副本的保存位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { parent = panel.url }
    }
}
