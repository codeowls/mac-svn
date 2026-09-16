import AppKit
import SwiftUI
import SVNCore

struct CheckoutView: View {
    @ObservedObject var model: AppModel
    @StateObject private var browser = RepositoryBrowserModel()
    @Environment(\.dismiss) private var dismiss
    @ViewState private var destination: URL?
    @ViewState private var showLogin = false

    private var checkoutUnavailableReason: String? {
        if model.isBusy {
            return "请等待当前操作完成。"
        }
        if browser.isLoading {
            return "正在浏览仓库，请稍候。"
        }
        if browser.checkoutURL.isEmpty {
            return "请输入仓库或分支地址。"
        }
        if destination == nil {
            return "请选择本地保存位置。"
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
                    Menu {
                        ForEach(model.recentRepositoryURLs, id: \.self) { address in
                            Button(address) {
                                browser.address = address
                                browser.addressChanged()
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                    .help("选择最近使用的仓库地址")
                    .accessibilityLabel("仓库地址历史")
                    .disabled(model.recentRepositoryURLs.isEmpty || browser.isLoading)
                    Button("浏览仓库") { withClient { browser.browse(using: $0) } }
                        .disabled(browser.checkoutURL.isEmpty || browser.isLoading)
                }
                HStack {
                    if let account = model.authenticationStore.authentication(for: browser.checkoutURL) {
                        Label("已登录：\(account.username)", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("私有仓库可先登录，再浏览或检出。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("仓库账号…") { showLogin = true }
                        .disabled(browser.checkoutURL.isEmpty || browser.isLoading || model.isBusy)
                }
                repositoryList
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("检出到本机").font(.headline)
                HStack {
                    Label(destination?.path ?? "选择或新建工作副本文件夹", systemImage: "folder")
                        .foregroundStyle(destination == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle).help(destination?.path ?? "")
                    Spacer()
                    Button("选择文件夹…") { chooseDestination() }
                }
                if let reason = checkoutUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("直接检出到所选的空文件夹，递归包含全部子目录和文件，不包含 externals（外部引用）。\n未在 App 登录时，使用本机 SVN 已缓存的认证。")
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
        .sheet(isPresented: $showLogin) {
            RepositoryLoginView(model: model, repository: browser.checkoutURL) {
                withClient { browser.browse(using: $0) }
            }
        }
        .onChange(of: browser.address) { _, _ in
            browser.addressChanged()
        }
        .onChange(of: browser.location) { _, location in
            if let location {
                model.rememberRepository(location.url)
            }
        }
        .onAppear {
            if browser.address.isEmpty {
                browser.address = model.recentRepositoryURLs.first ?? ""
            }
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
        do { action(try model.client(for: browser.checkoutURL)) }
        catch { browser.report(error) }
    }

    /// 所选目录就是检出目标，支持在系统选择器内新建空文件夹。
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择工作副本的保存位置"
        panel.prompt = "选择"
        panel.message = "选择或新建一个空文件夹，仓库内容将直接检出到这里。"
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        // 使用异步面板，避免新建文件夹弹窗与检出表单嵌套同步模态循环。
        panel.begin { response in
            if response == .OK {
                destination = panel.url
            }
        }
    }
}
