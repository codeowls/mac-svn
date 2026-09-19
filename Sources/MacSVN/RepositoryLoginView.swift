import SVNCore
import SwiftUI

struct RepositoryLoginView: View {
    @ObservedObject var model: AppModel
    let repository: String
    var onLogin: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var errorMessage: String?
    @ViewState private var request: Task<Void, Never>?
    @ViewState private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceHeading(title: L10n.text("登录 SVN 仓库"), icon: "person.crop.circle")
            Text(repository)
                .font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("账号"))
                TextField(L10n.text("SVN 账号"), text: $username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("SVN 账号"))
                Text(L10n.text("密码"))
                SecureField(L10n.text("SVN 密码"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("SVN 密码"))
                    .onSubmit { login() }
            }
            .padding(16)
            .modifier(WorkspacePanel())
            .disabled(isLoading)
            Text(L10n.text("密码仅用于本次 App 会话，退出后需重新登录。登录成功表示可以读取仓库，提交仍由服务器检查写权限。"))
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                ScrollView {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 100)
            }
            HStack {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在验证账号…")).font(.caption)
                }
                Spacer()
                Button(L10n.text("取消"), role: .cancel) {
                    request?.cancel()
                    password = ""
                    dismiss()
                }
                Button(L10n.text("登录")) { login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || model.isBusy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .modifier(WorkspaceBackground())
        .onAppear {
            username = model.authenticationStore.authentication(for: repository)?.username ?? ""
        }
        .onDisappear {
            request?.cancel()
            password = ""
        }
    }

    /// 失败时保留原始 SVN 诊断，用户修改凭据后主动重新验证。
    private func login() {
        guard !isLoading, !model.isBusy else {
            return
        }
        isLoading = true
        errorMessage = nil
        request = Task { @MainActor in
            defer { isLoading = false }
            do {
                try await model.authenticate(repository: repository, username: username, password: password)
                password = ""
                onLogin()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
