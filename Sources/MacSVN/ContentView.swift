import AppKit
import SwiftUI
import SVNCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showCheckout = false
    @ViewState private var showCommit = false
    @ViewState private var showLogin = false
    @ViewState private var showDiff = false
    @ViewState private var showOutput = false
    @ViewState private var recentPathPendingRemoval: String?
    @ViewState private var footerHeight: CGFloat = 44

    private let statusRowHeight: CGFloat = 44

    private var visibleEntries: [StatusEntry] {
        model.entries.filter { model.fileFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(model.fileFilter) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let copy = model.workingCopy {
                    workspaceHeader(copy)
                    Divider()
                    if model.showHistory {
                        HistoryView(model: model, onLogin: { showLogin = true })
                    } else {
                        changesView
                    }
                } else {
                    welcomeView
                }
                Divider()
                operationFooter
                    .background {
                        GeometryReader { geometry in
                            // 在详情列内读取实际高度，避免尺寸偏好被原生分栏边界截断。
                            Color.clear
                                .onAppear { footerHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in
                                    footerHeight = height
                                }
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseWorkingCopy() } label: {
                    Label("打开", systemImage: "folder")
                }
                .quickHelp("打开本地工作副本")
                .disabled(model.isBusy)
                Button { showCheckout = true } label: {
                    Label("检出远端", systemImage: "square.and.arrow.down")
                }
                .quickHelp("检出远端仓库到本机")
                .disabled(model.isBusy)
                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .quickHelp("刷新：重新读取本地状态")
                .disabled(model.isBusy || model.workingCopy == nil)
                Button { showLogin = true } label: {
                    Label("仓库账号", systemImage: "person.crop.circle")
                }
                .quickHelp("登录或切换当前仓库账号")
                .disabled(model.isBusy || model.workingCopy == nil)
                Button { model.update() } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .quickHelp("更新：从服务器获取最新版本")
                .disabled(model.isBusy || model.workingCopy == nil)
            }
        }
        .sheet(isPresented: $showCheckout) { CheckoutView(model: model) }
        .sheet(isPresented: $showCommit) { commitReview }
        .sheet(item: $model.directoryIgnoreDraft) { draft in
            DirectoryIgnoreView(model: model, draft: draft)
        }
        .sheet(item: $model.revertPlan) { plan in
            RevertReviewView(plan: plan, onCancel: { model.revertPlan = nil }) {
                model.confirmRevert(plan)
            }
        }
        .sheet(isPresented: $showDiff, onDismiss: { model.focusedPath = nil }) {
            DiffView(model: model)
        }
        .sheet(isPresented: $showLogin) {
            if let copy = model.workingCopy {
                RepositoryLoginView(model: model, repository: copy.repositoryURL) {
                    if model.showHistory { model.retryHistory() }
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("从最近列表移除此工作副本？", isPresented: Binding(
            get: { recentPathPendingRemoval != nil },
            set: { if !$0 { recentPathPendingRemoval = nil } }
        ), presenting: recentPathPendingRemoval) { path in
            Button("取消", role: .cancel) { recentPathPendingRemoval = nil }
            Button("移除记录", role: .destructive) {
                // 使用弹窗展示的路径，避免确认时误操作其他副本。
                model.removeRecentPath(path)
                recentPathPendingRemoval = nil
            }
            .disabled(model.isBusy)
        } message: { path in
            Text("\(path)\n\n仅移除最近记录，不会删除本地文件。该副本的会话草稿将被清除；如果当前已打开，也会关闭其工作区。")
        }
        .onChange(of: model.focusedPath) { _, _ in model.loadDiff() }
        .onChange(of: model.workingCopy?.root) { _, root in
            if root == nil {
                showCommit = false
                showOutput = false
            }
        }
        .onChange(of: model.checkoutProgress?.startedAt) { _, startedAt in
            if startedAt != nil {
                showOutput = true
            }
        }
        .onChange(of: model.writeProgress?.id) { _, id in
            if id != nil { showOutput = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 36, height: 36)
                Text("Mac SVN").font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 12)
            VStack(spacing: 8) {
                Button { showCheckout = true } label: {
                    Label("检出远端", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .buttonStyle(.plain)
                Button { model.chooseWorkingCopy() } label: {
                    Label("打开本地工作副本", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .buttonStyle(.plain)
            }
            .disabled(model.isBusy)
            VStack(alignment: .leading, spacing: 10) {
                Text("最近的工作副本").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.recentPaths, id: \.self) { path in
                            Button {
                                model.open(URL(fileURLWithPath: path))
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.body.weight(.medium)).lineLimit(1)
                                        Text(path).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(path).disabled(model.isBusy)
                            .background(model.workingCopy?.root.path == path ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu {
                                Button {
                                    model.refresh(at: URL(fileURLWithPath: path))
                                } label: {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                                .disabled(model.isBusy)
                                Button {
                                    model.update(at: URL(fileURLWithPath: path))
                                } label: {
                                    Label("更新", systemImage: "arrow.down.circle")
                                }
                                .disabled(model.isBusy)
                                Divider()
                                Button("删除…", role: .destructive) {
                                    recentPathPendingRemoval = path
                                }
                                .disabled(model.isBusy)
                                .help("仅从最近列表删除，不删除本地文件")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    SettingsLink { Label("设置", systemImage: "gearshape") }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: statusRowHeight)
                .frame(height: footerHeight, alignment: .top)
            }
        }
    }

    private func workspaceHeader(_ copy: WorkingCopy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(copy.root.lastPathComponent).font(.system(size: 24, weight: .semibold))
                    Label(copy.repositoryURL, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { showLogin = true } label: {
                    Label(
                        model.authenticationStore.authentication(for: copy.repositoryURL)
                            .map { "账号：\($0.username)" } ?? "未在 App 登录",
                        systemImage: "person.crop.circle"
                    )
                    .font(.caption)
                }
                .disabled(model.isBusy)
                .help("账号按仓库地址隔离；未在 App 登录时使用本机 SVN 已有的认证配置。密码仅保留在当前 App 会话。")
                Text("r\(copy.revision)").font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 8) {
                tab("本地变更", count: model.entries.count, selected: !model.showHistory) {
                    model.showHistory = false
                }
                tab("提交历史", count: nil, selected: model.showHistory) { model.showSavedHistory() }
                Spacer()
                Text(copy.root.path).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(copy.root.path)
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
    }

    private func tab(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(model.isBusy)
    }

    private var changesView: some View {
        VStack(spacing: 0) {
            fileComparisonView
            commitEditor
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var fileComparisonView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("筛选文件路径", text: $model.fileFilter)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBusy)
                Menu("目录忽略") {
                    Button("编辑工作副本根目录…") { model.editDirectoryIgnores() }
                    Button("选择受控目录…") { model.chooseDirectoryIgnores() }
                }
                .fixedSize().disabled(model.isBusy)
                Toggle("显示已忽略项", isOn: Binding(
                    get: { model.showIgnored },
                    set: {
                        model.showIgnored = $0
                        model.refresh()
                    }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(model.isBusy)
                Text("\(visibleEntries.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if model.entries.isEmpty {
                ContentUnavailableView("工作副本干净", systemImage: "checkmark.circle", description: Text("当前没有本地变更"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                ContentUnavailableView("没有匹配的文件", systemImage: "magnifyingglass", description: Text("试试其他路径关键词"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(visibleEntries) { entry in
                            HStack(spacing: 10) {
                                Toggle("选择 \(entry.path)", isOn: Binding(
                                    get: { model.selectedPaths.contains(entry.path) },
                                    set: { selected in
                                        if selected { model.selectedPaths.insert(entry.path) }
                                        else { model.selectedPaths.remove(entry.path) }
                                    }
                                ))
                                .labelsHidden().toggleStyle(.checkbox)
                                .disabled(model.isBusy || (!entry.canCommit && !entry.canRevert && entry.item != "unversioned"))
                                Button {
                                    model.focusedPath = entry.path
                                    showDiff = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.path).font(.system(size: 12, weight: .medium))
                                                .lineLimit(2).multilineTextAlignment(.leading)
                                            Text(entry.label).font(.caption2).foregroundStyle(statusColor(entry))
                                                .help(entry.item == "unversioned"
                                                    ? "仅存在于本地，尚未加入 SVN；点击查看说明"
                                                    : entry.item == "ignored" ? "匹配 SVN 忽略规则；点击查看说明" : "点击查看文件差异")
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(model.isBusy)
                            }
                            .padding(11)
                            .background(model.focusedPath == entry.path ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contextMenu {
                                Button("查看此路径历史") { model.loadHistory(path: entry.path) }
                                    .disabled(model.isBusy || !entry.canReadHistory)
                                Button("还原此项目…") { model.prepareRevert(paths: [entry.path]) }
                                    .disabled(model.isBusy || !entry.canRevert)
                                Divider()
                                if entry.item == "unversioned" {
                                    Button("忽略此名称…") { model.ignoreUnversioned(entry) }
                                        .disabled(model.isBusy)
                                    if !model.isLocalDirectory(entry.path), !(entry.path as NSString).pathExtension.isEmpty {
                                        Button("忽略同扩展名…") { model.ignoreUnversioned(entry, byExtension: true) }
                                            .disabled(model.isBusy)
                                    }
                                }
                                Button("编辑所在目录忽略…") {
                                    model.editDirectoryIgnores(path: model.parentDirectory(of: entry.path))
                                }
                                .disabled(model.isBusy)
                                if model.isLocalDirectory(entry.path), !["unversioned", "ignored"].contains(entry.item) {
                                    Button("编辑此目录忽略…") { model.editDirectoryIgnores(path: entry.path) }
                                        .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("已选 \(model.selectedPaths.count) 项").font(.caption)
                Spacer()
                Button("取消选择") { model.selectedPaths = [] }
                    .disabled(model.isBusy || model.selectedPaths.isEmpty)
                Button("添加到 SVN") { model.addSelected() }
                    .disabled(!model.canAdd)
                Button("还原选中项…") { model.prepareRevert() }
                    .disabled(!model.canRevert)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func statusColor(_ entry: StatusEntry) -> Color {
        if entry.isConflict || entry.item == "deleted" { return .red }
        if entry.item == "added" { return .green }
        return ["unversioned", "ignored"].contains(entry.item) ? .secondary : .orange
    }

    private var commitEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("提交变更").font(.headline)
                Spacer()
                Text("已选 \(model.selectedPaths.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(.body).scrollContentBackground(.hidden).frame(height: 54)
                    .disabled(model.isBusy)
                if model.message.isEmpty {
                    Text("描述这次变更…").foregroundStyle(.tertiary)
                        .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            HStack {
                Text("仅提交勾选项目，目录不自动包含子项")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showCommit = true } label: {
                    Label("检查并提交", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent).tint(Color(nsColor: .labelColor))
                .disabled(!model.canCommit)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
        .padding(16)
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 10) {
                Text("你的项目，从这里开始").font(.system(size: 30, weight: .semibold))
                Text("连接 SVN 仓库，让文件变更与提交记录一目了然。")
                    .font(.body).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                welcomeAction("检出远端分支", subtitle: "连接仓库，浏览并下载需要的分支", icon: "arrow.down.to.line") {
                    showCheckout = true
                }
                welcomeAction("打开本地工作副本", subtitle: "继续处理已经检出的项目", icon: "folder") {
                    model.chooseWorkingCopy()
                }
            }
            .disabled(model.isBusy)
            Text("支持 SVN 1.14+ · 引擎路径可在设置中调整")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(width: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeAction(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            .padding(20).contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }

    private var operationFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "terminal").foregroundStyle(.secondary) }
                Text(model.isBusy ? model.operation : (model.result.components(separatedBy: "\n").first ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.isBusy { Button("取消") { model.cancel() }.controlSize(.small) }
                Button { showOutput.toggle() } label: {
                    Label(showOutput ? "收起输出" : "操作输出", systemImage: showOutput ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: statusRowHeight)
            if let progress = model.writeProgress {
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(progress.title) · \(progress.phase.rawValue)")
                            Spacer()
                            let elapsed = Int((progress.finishedAt ?? context.date).timeIntervalSince(progress.startedAt))
                            Text("已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒").monospacedDigit()
                        }
                        if progress.phase == .running, context.date.timeIntervalSince(progress.lastOutputAt) >= 5 {
                            Text("等待 SVN 新输出；取消不会撤销已完成的操作。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .padding(.bottom, 12)
            }
            if let progress = model.checkoutProgress {
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("已检出 \(progress.completedItemCount) 项（文件/目录）")
                            Spacer()
                            let elapsed = Int(context.date.timeIntervalSince(progress.startedAt))
                            Text("已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒")
                                .monospacedDigit()
                        }
                        if progress.isOpeningWorkingCopy {
                            Text("下载完成，正在读取工作副本…")
                        } else if let path = progress.lastCompletedPath {
                            Text("最近完成：\(path)")
                                .lineLimit(1).truncationMode(.middle).help(path)
                        } else {
                            Text("正在连接仓库，等待检出输出…")
                        }
                        if !progress.isOpeningWorkingCopy,
                           context.date.timeIntervalSince(progress.lastOutputAt) >= 5 {
                            Text("等待 SVN 新输出；大文件传输时可能暂时没有新记录，可取消操作。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .padding(.bottom, 12)
            }
            if showOutput {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("output-end")
                    }
                    .onChange(of: model.result) { _, _ in
                        if model.checkoutProgress != nil || model.writeProgress != nil {
                            proxy.scrollTo("output-end", anchor: .bottom)
                        }
                    }
                }
                .frame(height: 100)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 18)
    }

    private var commitReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认提交 \(model.selectedPaths.count) 个项目").font(.title2.bold())
            Text(model.workingCopy?.repositoryURL ?? "").font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.selectedPaths.sorted(), id: \.self) { path in
                        Text(path).font(.system(.body, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text(model.message).textSelection(.enabled)
            HStack {
                Spacer()
                Button("返回检查", role: .cancel) { showCommit = false }
                Button("提交到仓库") {
                    showCommit = false
                    model.commitSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
