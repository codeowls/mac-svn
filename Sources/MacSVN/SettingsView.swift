import AppKit
import SwiftUI
import SVNCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var tab = "general"
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.chinese.rawValue
    @ViewState private var executablePath = ""
    @ViewState private var useCustomIgnores = false
    @ViewState private var ignorePatterns = ""
    @ViewState private var feedback = ""
    @ViewState private var isError = false
    @ViewState private var isTesting = false
    @ViewState private var request: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceHeading(title: L10n.text("SVN 设置"), icon: "gearshape")
            Picker(L10n.text("设置分类"), selection: $tab) {
                Text(L10n.text("通用")).tag("general")
                Text("SVN").tag("engine")
                Text(L10n.text("忽略")).tag("ignores")
                Text(L10n.text("合并工具")).tag("merge")
                Text(L10n.text("访达")).tag("finder")
            }
            .pickerStyle(.segmented)
            .frame(width: 460)

            Group {
                if tab == "general" {
                    generalSettings
                } else if tab == "engine" {
                    engineSettings
                } else if tab == "finder" {
                    FinderIntegrationSettings(model: model)
                } else if tab == "merge" {
                    MergeToolSettingsView()
                } else {
                    ignoreSettings
                }
            }
            .disabled(tab != "general" && (model.isBusy || isTesting))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(WorkspacePanel())

            if tab == "engine" || tab == "ignores" {
                Divider()
                HStack(alignment: .top) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在检查 SVN…")).font(.caption)
                        Button(L10n.text("取消")) { request?.cancel() }
                    } else {
                        Text(model.isBusy ? L10n.text("当前有操作正在进行，请完成后保存。") : feedback)
                            .font(.caption)
                            .foregroundStyle(isError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Button(L10n.text("保存设置")) { testExecutable(save: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || isTesting)
                }
                .frame(minHeight: 38)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .modifier(WorkspaceBackground())
        .onAppear { loadSavedSettings() }
        .onDisappear { request?.cancel() }
        .onChange(of: executablePath) { _, _ in clearFeedback() }
        .onChange(of: useCustomIgnores) { _, _ in clearFeedback() }
        .onChange(of: ignorePatterns) { _, _ in clearFeedback() }
        .onChange(of: language) { _, value in
            AppLanguage(rawValue: value)?.save()
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("界面语言")).font(.headline)
            Picker(L10n.text("语言"), selection: $language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .frame(maxWidth: 300)
            Text(L10n.text("语言选择自动保存，重新打开 Mac SVN 后生效。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if language != L10n.language.rawValue {
                Label(L10n.text("语言已保存，请退出并重新打开应用。"), systemImage: "info.circle")
                    .font(.callout)
            }
        }
    }

    private var engineSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("SVN 可执行文件")).font(.headline)
            TextField(L10n.text("例如 /opt/homebrew/bin/svn"), text: $executablePath)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.text("SVN 可执行文件路径"))
            HStack {
                Button(L10n.text("选择文件…")) { chooseExecutable() }
                Button(L10n.text("自动检测")) { discoverExecutable() }
                Button(L10n.text("测试")) { testExecutable(save: false) }
            }
            Text(L10n.text("使用本机安装的 SVN 1.14 或更新版本。测试仅查询本机版本，不连接仓库；保存前会再次检查。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L10n.text("尚未安装时，可在终端运行："))
                .font(.caption).foregroundStyle(.secondary)
            Text("brew install subversion")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text(L10n.text("仓库账号在检出窗口或工具栏中管理。可选择将密码保存到本机钥匙串，也可退出并清除已保存密码；未登录时沿用系统 SVN 认证配置。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ignoreSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.text("使用自定义全局忽略列表（仅此应用）"), isOn: $useCustomIgnores)
                .toggleStyle(.checkbox)
            Text(useCustomIgnores
                 ? L10n.text("保存后用于本应用的所有工作副本，替代系统的全局忽略列表；目录忽略属性仍然生效。")
                 : L10n.text("当前沿用系统 SVN 的忽略配置。启用自定义后可编辑下方规则。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("文件或目录名称模式，以空格或换行分隔"))
                .font(.callout)
            TextEditor(text: $ignorePatterns)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .frame(height: 130)
                .disabled(!useCustomIgnores)
                .accessibilityLabel(L10n.text("全局忽略文件模式"))
            HStack {
                Button(L10n.text("填入常用规则")) {
                    ignorePatterns = SVNConfiguration.suggestedGlobalIgnores
                }
                .disabled(!useCustomIgnores)
                Spacer()
                Text(L10n.text("例如：.DS_Store  .idea  *.iml"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("只影响未受版本控制的项目，不删除文件，也不隐藏已受控文件的修改。\n支持 *、?、[abc] 通配符；不是 .gitignore 语法。自定义列表留空表示不设置全局忽略。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadSavedSettings() {
        executablePath = model.executablePath
        useCustomIgnores = model.globalIgnores != nil
        ignorePatterns = model.globalIgnores ?? SVNConfiguration.suggestedGlobalIgnores
        clearFeedback()
    }

    private func clearFeedback() {
        feedback = ""
        isError = false
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 SVN 可执行文件")
        panel.prompt = L10n.text("选择")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
        }
    }

    private func discoverExecutable() {
        if let url = SVNClient.discoverExecutable() {
            executablePath = url.path
        } else {
            feedback = L10n.text("未在常见安装位置找到 SVN，请安装或手动选择。")
            isError = true
        }
    }

    /// 测试与保存使用同一版本检查；编辑草稿不会提前影响正在使用的配置。
    private func testExecutable(save: Bool) {
        guard !isTesting, !model.isBusy else { return }
        clearFeedback()
        isTesting = true
        let path = executablePath
        let patterns = useCustomIgnores ? ignorePatterns : nil
        request = Task { @MainActor in
            defer { isTesting = false }
            do {
                let executable = try SVNConfiguration.executableURL(for: path)
                let normalized = try patterns.map(SVNConfiguration.normalizeIgnorePatterns)
                let client = SVNClient(executable: executable, globalIgnores: normalized)
                let version = try await client.version()
                try Task.checkCancellation()
                if save {
                    try model.saveSettings(executablePath: executable.path, globalIgnores: normalized)
                    feedback = L10n.text("设置已保存 · SVN %@。当前副本会刷新，其他副本下次打开时生效。", version)
                } else {
                    feedback = L10n.text("测试通过 · SVN %@", version)
                }
            } catch is CancellationError {
                feedback = L10n.text("检查已取消，设置未保存。")
            } catch {
                feedback = error.localizedDescription
                isError = true
            }
        }
    }
}
