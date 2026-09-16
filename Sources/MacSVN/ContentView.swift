import AppKit
import SwiftUI
import SVNCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showCheckout = false
    @ViewState private var showCommit = false
    @ViewState private var filter = ""
    @ViewState private var showOutput = false

    private var visibleEntries: [StatusEntry] {
        model.entries.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
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
                    Label("检出远端", systemImage: "square.and.arrow.down")
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
        .toolbarBackground(.hidden, for: .windowToolbar)
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
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
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
                                filter = ""
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
                                .background(model.workingCopy?.root.path == path ? Color.primary.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(path).disabled(model.isBusy)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            SettingsLink { Label("设置", systemImage: "gearshape") }
                .buttonStyle(.plain).padding(.horizontal, 10)
        }
        .padding(.horizontal, 14).padding(.bottom, 20)
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
                Text("r\(copy.revision)").font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 8) {
                tab("本地变更", count: model.entries.count, selected: !model.showHistory) {
                    model.showHistory = false
                }
                tab("提交历史", count: nil, selected: model.showHistory) { model.loadHistory() }
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
                                    .disabled(model.isBusy || (!entry.canCommit && entry.item != "unversioned"))
                                    Button { model.focusedPath = entry.path } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(entry.path).font(.system(size: 12, weight: .medium))
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                Text(entry.label).font(.caption2).foregroundStyle(statusColor(entry))
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
                }
                .padding(10)
            }
            .frame(minWidth: 320, idealWidth: 390)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(model.focusedPath ?? "文件差异", systemImage: "doc.text")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text(highlightedDiff)
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(5).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 340)
        }
    }

    private func statusColor(_ entry: StatusEntry) -> Color {
        if entry.isConflict || entry.item == "deleted" { return .red }
        if entry.item == "added" { return .green }
        return entry.item == "unversioned" ? .secondary : .orange
    }

    /// Keep SVN's original diff text selectable while distinguishing additions and removals.
    private var highlightedDiff: AttributedString {
        var result = AttributedString()
        let lines = model.diffText.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var part = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("+") { part.foregroundColor = .green }
            else if line.hasPrefix("-") { part.foregroundColor = .red }
            else if line.hasPrefix("@@") { part.foregroundColor = .secondary }
            result.append(part)
        }
        return result
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
        VStack(alignment: .leading, spacing: 10) {
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
            if showOutput {
                ScrollView {
                    Text(model.result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
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
