import AppKit
import SwiftUI
import SVNCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showCheckout = false
    @ViewState private var showLogin = false
    @ViewState private var showDiff = false
    @ViewState private var showOutput = false
    @ViewState private var followsOutput = true
    @ViewState private var recentPathPendingRemoval: String?
    @ViewState private var pathPendingCleanup: String?
    @ViewState private var footerHeight: CGFloat = 44

    @ViewState private var hoveredPath: String?
    @ViewState private var commitExpanded = false

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
                    .background(.bar)
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
            .modifier(WorkspaceBackground())
        }
        .tint(WorkspaceStyle.accent)
        .background(ViewWindowReader { model.mainWindow = $0 })
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
        .sheet(item: $model.commitPlan) { plan in
            CommitReviewView(model: model, plan: plan)
        }
        .sheet(item: $model.fileOperationDraft) { draft in
            FileOperationView(model: model, draft: draft)
        }
        .sheet(item: $model.directoryIgnoreDraft) { draft in
            DirectoryIgnoreView(model: model, draft: draft)
        }
        .sheet(item: $model.conflictDetails) { details in
            ConflictView(model: model, details: details).id(details.id)
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
        .sheet(isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            OperationErrorView(message: model.errorMessage ?? "") {
                model.errorMessage = nil
            }
        }
        .alert("清理工作副本锁？", isPresented: Binding(
            get: { pathPendingCleanup != nil },
            set: { if !$0 { pathPendingCleanup = nil } }
        ), presenting: pathPendingCleanup) { path in
            Button("取消", role: .cancel) { pathPendingCleanup = nil }
            Button("清理") {
                pathPendingCleanup = nil
                model.cleanup(at: URL(fileURLWithPath: path))
            }
            .disabled(model.isBusy)
        } message: { path in
            Text("\(path)\n\n请确认其他 SVN 客户端或终端已停止操作此副本。清理会完成未完成的本地管理任务并释放工作副本锁，不删除未受控文件。完成后可手动更新。")
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
        .onChange(of: model.selectedPaths) { previous, current in
            // 首次勾选时展开；取消选择不收起正在编辑的说明。
            if previous.isEmpty && !current.isEmpty { commitExpanded = true }
        }
        .onChange(of: model.workingCopy?.root) { _, root in
            commitExpanded = !model.message.isEmpty || !model.selectedPaths.isEmpty
            if root == nil {
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 36, height: 36)
                Text("Mac SVN").font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 12)
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
                                    Image(systemName: model.workingCopy?.root.path == path ? "folder.fill" : "folder")
                                        .foregroundStyle(model.workingCopy?.root.path == path ? WorkspaceStyle.accent : .secondary)
                                        .padding(.top, 2)
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
                            .buttonStyle(SidebarActionStyle()).help(path).disabled(model.isBusy)
                            .background(model.workingCopy?.root.path == path ? WorkspaceStyle.accent.opacity(0.13) : .clear,
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
                                Button {
                                    pathPendingCleanup = path
                                } label: {
                                    Label("清理工作副本锁…", systemImage: "wrench.and.screwdriver")
                                        .labelStyle(.titleAndIcon)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(copy.root.lastPathComponent, systemImage: "externaldrive.connected.to.line.below")
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                    .foregroundStyle(WorkspaceStyle.accent)
                    .background(WorkspaceStyle.accent.opacity(0.10), in: Capsule())
            }
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    tab("本地变更", count: model.entries.count, selected: !model.showHistory) {
                        model.showHistory = false
                    }
                    tab("提交历史", count: nil, selected: model.showHistory) {
                        model.showSavedHistory()
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                Text(copy.root.path).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(copy.root.path)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private func tab(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(selected ? WorkspaceStyle.accent : .secondary)
            .background(selected ? WorkspaceStyle.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).disabled(model.isBusy)
    }

    private var changesView: some View {
        VStack(spacing: 12) {
            fileComparisonView
            commitEditor
        }
        .padding(16)
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
            .background(Color.primary.opacity(0.025))
            Divider()
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
                                    if entry.isConflict {
                                        model.inspectConflict(path: entry.path)
                                    } else {
                                        model.focusedPath = entry.path
                                        showDiff = true
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: statusIcon(entry))
                                            .font(.system(size: 17))
                                            .foregroundStyle(statusColor(entry))
                                            .frame(width: 24)
                                        Text(entry.path)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .help(entry.path)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        WorkspaceBadge(title: entry.label, color: statusColor(entry))
                                            .fixedSize()
                                            .help(entry.item == "unversioned"
                                                ? "仅存在于本地，尚未加入 SVN；点击查看说明"
                                                : entry.item == "ignored" ? "匹配 SVN 忽略规则；点击查看说明"
                                                : entry.isConflict ? "点击查看冲突详情" : "点击查看文件差异")
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(model.isBusy)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(statusRowBackground(entry), in: RoundedRectangle(cornerRadius: 8))
                            .onHover { isHovered in
                                hoveredPath = isHovered ? entry.path : (hoveredPath == entry.path ? nil : hoveredPath)
                            }
                            .contextMenu {
                                if entry.isConflict {
                                    Button("查看冲突详情…") { model.inspectConflict(path: entry.path) }
                                        .disabled(model.isBusy)
                                }
                                Button("查看此路径历史") { model.loadHistory(path: entry.path) }
                                    .disabled(model.isBusy || !entry.canReadHistory)
                                if entry.path != ".", !entry.isConflict,
                                   !["unversioned", "ignored", "external", "deleted", "obstructed", "incomplete"].contains(entry.item) {
                                    Button("重命名…") { model.beginFileOperation(.rename, path: entry.path) }
                                        .disabled(model.isBusy)
                                    Button("删除…", role: .destructive) { model.beginFileOperation(.delete, path: entry.path) }
                                        .disabled(model.isBusy)
                                }
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
                Menu("文件操作") {
                    Button("选择项目重命名…") { model.chooseFileOperation(.rename) }
                    Button("选择项目删除…") { model.chooseFileOperation(.delete) }
                }
                .disabled(model.isBusy)
                Button("添加到 SVN") { model.addSelected() }
                    .disabled(!model.canAdd)
                Button("还原选中项…") { model.prepareRevert() }
                    .disabled(!model.canRevert)
            }
            .padding(10)
            .background(Color.primary.opacity(0.025))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .modifier(WorkspacePanel())
    }

    /// 勾选范围与查看焦点共用强调色，悬停仅作轻量提示。
    private func statusRowBackground(_ entry: StatusEntry) -> Color {
        if model.selectedPaths.contains(entry.path) || model.focusedPath == entry.path {
            return WorkspaceStyle.accent.opacity(0.10)
        }
        return hoveredPath == entry.path && !model.isBusy ? Color.primary.opacity(0.045) : .clear
    }

    /// 冲突优先显示警示符号，其余项目按本地文件类型展示。
    private func statusIcon(_ entry: StatusEntry) -> String {
        if entry.isConflict { return "exclamationmark.triangle.fill" }
        return model.isLocalDirectory(entry.path) ? "folder" : "doc.text"
    }

    private func statusColor(_ entry: StatusEntry) -> Color {
        if entry.isConflict || entry.item == "deleted" { return .red }
        if entry.item == "added" { return .green }
        return ["unversioned", "ignored"].contains(entry.item) ? .secondary : .orange
    }

    private var commitEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { commitExpanded.toggle() } label: {
                    Label("提交变更", systemImage: commitExpanded ? "chevron.down" : "chevron.right")
                        .font(.headline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(commitExpanded ? "收起提交说明" : "展开提交说明")
                .help("折叠不会清除提交说明")
                Text("已选 \(model.selectedPaths.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !commitExpanded && !model.message.isEmpty {
                    WorkspaceBadge(title: "有草稿", color: WorkspaceStyle.accent)
                }
                Spacer(minLength: 0)
                Button { model.prepareCommitSelected() } label: {
                    Label("检查并提交", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
            }
            if commitExpanded {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.message)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 64)
                        .disabled(model.isBusy)
                        .accessibilityLabel("提交说明")
                    if model.message.isEmpty {
                        Text("描述这次变更…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(WorkspaceStyle.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(WorkspaceStyle.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                Text("提交前检查范围；重命名和目录结构操作会列出关联项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .modifier(WorkspacePanel())
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .padding(18)
                .background(WorkspaceStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
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
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(WorkspaceStyle.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            .padding(20).contentShape(Rectangle())
            .modifier(WorkspacePanel())
        }
        .buttonStyle(SidebarActionStyle())
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
            if let recovery = model.checkoutRecovery {
                VStack(alignment: .leading, spacing: 6) {
                    Text("检出目录：\(recovery.destination.path)").textSelection(.enabled)
                    if let inspection = recovery.inspection {
                        Text(inspection.summary)
                        Text(inspection.guidance).foregroundStyle(.secondary)
                        if let copy = inspection.workingCopy {
                            Text(copy.repositoryURL).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else if let error = recovery.error {
                        Text("目录检查失败：\(error)").foregroundStyle(.red).textSelection(.enabled)
                        Text("请在访达中检查保留的内容；修正错误后可重新检查目录。")
                    } else {
                        Text("正在检查残留目录…")
                    }
                    HStack {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([recovery.destination])
                        }
                        Button("重新检查") { model.recheckCheckout() }
                        if recovery.inspection?.workingCopy != nil {
                            Button("打开并检查") { model.open(recovery.destination) }
                        }
                        Spacer()
                        Button("收起提示") { model.checkoutRecovery = nil }
                    }
                    .disabled(model.isBusy)
                }
                .font(.caption)
                .padding(.bottom, 12)
            }
            if let progress = model.writeProgress, model.checkoutProgress == nil {
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    let awaitingOutput = progress.phase == .running
                        && context.date.timeIntervalSince(progress.lastOutputAt) >= 5
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(progress.title) · \(progress.phase.rawValue)")
                            Spacer()
                            let elapsed = Int((progress.finishedAt ?? context.date).timeIntervalSince(progress.startedAt))
                            Text("已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒").monospacedDigit()
                        }
                        // 等待提示保留一行高度，输出恢复时不改变面板及侧栏分割线位置。
                        Text("等待 SVN 新输出；取消不会撤销已完成的操作。")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(awaitingOutput ? 1 : 0)
                            .accessibilityHidden(!awaitingOutput)
                    }
                    .font(.caption)
                }
                .padding(.bottom, 12)
            }
            if let progress = model.checkoutProgress {
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    let awaitingOutput = !progress.isOpeningWorkingCopy
                        && context.date.timeIntervalSince(progress.lastOutputAt) >= 5
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
                        // 大文件下载期间只切换提示可见性，不反复插入、移除布局行。
                        Text("等待 SVN 新输出；大文件传输时可能暂时没有新记录，可取消操作。")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(awaitingOutput ? 1 : 0)
                            .accessibilityHidden(!awaitingOutput)
                    }
                    .font(.caption)
                }
                .padding(.bottom, 12)
            }
            if showOutput {
                HStack {
                    Toggle("跟随最新输出", isOn: $followsOutput).toggleStyle(.checkbox)
                    Spacer()
                    Button("复制完整输出") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.result, forType: .string)
                    }
                }
                .font(.caption)
                .padding(.bottom, 6)
                OperationOutputView(text: model.result, followsOutput: followsOutput)
                .frame(height: 100)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 18)
    }

}
