import AppKit
import SwiftUI
import SVNCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showCheckout = false
    @ViewState private var showCommit = false
    @ViewState private var filter = ""

    private var visibleEntries: [StatusEntry] {
        model.entries.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let copy = model.workingCopy {
                    workspaceHeader(copy)
                    Divider()
                    if model.showHistory {
                        historyView
                    } else {
                        changesView
                    }
                } else {
                    welcomeView
                }
                Divider()
                operationFooter
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseWorkingCopy() } label: {
                    Label("打开", systemImage: "folder")
                }
                .disabled(model.isBusy)
                Button { showCheckout = true } label: {
                    Label("检出", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isBusy)
                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || model.workingCopy == nil)
                Button { model.update() } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .disabled(model.isBusy || model.workingCopy == nil)
            }
        }
        .sheet(isPresented: $showCheckout) { CheckoutView(model: model) }
        .sheet(isPresented: $showCommit) { commitReview }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.focusedPath) { _, _ in model.loadDiff() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Mac SVN", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.bold())
                .padding(.top, 12)
            Text("工作副本").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.recentPaths, id: \.self) { path in
                        Button {
                            filter = ""
                            model.open(URL(fileURLWithPath: path))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                                    .font(.body.weight(.medium))
                                Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(model.workingCopy?.root.path == path ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                    }
                }
            }
            Spacer()
            Text("首版 · 本机 SVN 引擎\n外部工作副本（externals）不参与检出或更新")
                .font(.caption2).foregroundStyle(.secondary)
            SettingsLink { Label("设置", systemImage: "gearshape") }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func workspaceHeader(_ copy: WorkingCopy) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(copy.root.lastPathComponent).font(.title2.bold())
                Text(copy.repositoryURL).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1)
            }
            Spacer()
            Button("本地变更") { model.showHistory = false }
                .disabled(!model.showHistory)
            Button("历史记录") { model.loadHistory() }
                .disabled(model.isBusy)
        }
        .padding(18)
    }

    private var changesView: some View {
        VStack(spacing: 0) {
            fileComparisonView
            commitEditor
        }
    }

    private var fileComparisonView: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("筛选文件路径", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Text("\(model.entries.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                if model.entries.isEmpty {
                    ContentUnavailableView("工作副本干净", systemImage: "checkmark.circle", description: Text("当前没有本地变更"))
                } else {
                    List(selection: $model.focusedPath) {
                        ForEach(visibleEntries) { entry in
                            HStack(spacing: 9) {
                                Toggle("选择 \(entry.path)", isOn: Binding(
                                    get: { model.selectedPaths.contains(entry.path) },
                                    set: { selected in
                                        if selected { model.selectedPaths.insert(entry.path) }
                                        else { model.selectedPaths.remove(entry.path) }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(model.isBusy || (!entry.canCommit && entry.item != "unversioned"))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.path).font(.system(.body, design: .monospaced)).lineLimit(2)
                                    Text(entry.label).font(.caption)
                                        .foregroundStyle(entry.isConflict ? Color.red : Color.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .tag(entry.path)
                        }
                    }
                    .listStyle(.inset)
                    .disabled(model.isBusy)
                }
                Divider()
                HStack {
                    Text("已选 \(model.selectedPaths.count) 项").font(.caption)
                    Spacer()
                    Button("取消选择") { model.selectedPaths = [] }
                        .disabled(model.isBusy || model.selectedPaths.isEmpty)
                    Button("添加到 SVN") { model.addSelected() }
                        .disabled(!model.canAdd)
                }
                .padding(10)
            }
            .frame(minWidth: 320, idealWidth: 390)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("文件差异", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    if let path = model.focusedPath, let copy = model.workingCopy {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([copy.root.appendingPathComponent(path)])
                        }
                    }
                }
                .padding(12)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(model.diffText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 340)
        }
    }

    private var commitEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("提交说明").font(.headline)
                Spacer()
                Text("仅提交勾选项目；目录不会自动包含子项").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 14) {
                TextEditor(text: $model.message)
                    .font(.body)
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .disabled(model.isBusy)
                Button("检查并提交…") { showCommit = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCommit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.background)
    }

    private var historyView: some View {
        List(model.logs) { log in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("r\(log.revision)").font(.system(.headline, design: .monospaced))
                    Text(log.author).font(.subheadline)
                    Spacer()
                    Text(log.date).font(.caption).foregroundStyle(.secondary)
                }
                Text(log.message.isEmpty ? "（无提交说明）" : log.message)
                    .textSelection(.enabled)
            }
            .padding(10)
        }
        .overlay {
            if model.logs.isEmpty && !model.isBusy {
                ContentUnavailableView("暂无历史记录", systemImage: "clock")
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 60)).foregroundStyle(.tint)
            Text("让 SVN 的日常操作更简单").font(.largeTitle.bold())
            Text("打开工作副本，查看差异，选择文件并提交。")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("打开工作副本…") { model.chooseWorkingCopy() }
                    .buttonStyle(.borderedProminent)
                Button("检出仓库…") { showCheckout = true }
            }
            .disabled(model.isBusy)
            Text("需要 SVN 1.14+ · 可在设置中指定安装路径")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var operationFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.operation).font(.caption)
                    Spacer()
                    Button("取消") { model.cancel() }.controlSize(.small)
                }
            }
            ScrollView {
                Text(model.result).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 44)
        }
        .padding(10)
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
