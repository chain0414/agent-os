import SwiftUI

struct ServiceEntryView: View {
    private enum LoginMethod {
        case password, feishu
    }

    private enum Field {
        case email, password
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var oauthLogin = OAuthLoginCoordinator()
    @State private var showsPrivacyPolicy = false
    @State private var email = ""
    @State private var password = ""
    @State private var loginMethod: LoginMethod?
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollView {
            AuthWelcomeLayout {
                AuthBrandLockup()
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 16) {
                    credentials

                    if let error = appState.authError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("auth.error")
                    }

                    loginActions
                }
                .frame(maxWidth: 340)
            }
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.appBackground(colorScheme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if focusedField == nil {
                Button("privacyPolicy.title") { showsPrivacyPolicy = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicySheet()
        }
    }

    private var credentials: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                fieldLabel("Email", for: .email)
                TextField(
                    "Email",
                    text: $email,
                    prompt: Text(verbatim: "name@example.com")
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                )
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .focused($focusedField, equals: .email)
                .accessibilityLabel(Text("Email"))
                .accessibilityIdentifier("auth.email")
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                fieldLabel("Password", for: .password)
                SecureField("Password", text: $password, prompt: Text(verbatim: ""))
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { startLogin(.password) }
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel(Text("Password"))
                    .accessibilityIdentifier("auth.password")
            }
        }
        .textFieldStyle(.plain)
        .font(.body)
        .padding(.horizontal, 16)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 16))
        .disabled(loginMethod != nil)
    }

    private func fieldLabel(_ title: LocalizedStringKey, for field: Field) -> some View {
        Text(title)
            .fontWeight(.medium)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .onTapGesture {
                if loginMethod == nil { focusedField = field }
            }
            .accessibilityHidden(true)
    }

    private var loginActions: some View {
        VStack(spacing: 20) {
            AppGlassButton(
                String(localized: "Log In"),
                style: canSubmitPassword || loginMethod == .password ? .prominent : .regular,
                isLoading: loginMethod == .password,
                disabled: !canSubmitPassword,
            ) {
                startLogin(.password)
            }
            .accessibilityIdentifier("auth.sign-in")

            AppGlassButton(
                String(localized: "Sign in with Feishu"),
                isLoading: loginMethod == .feishu,
                disabled: loginMethod != nil,
            ) {
                startLogin(.feishu)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("auth.feishu")
        }
    }

    private var canSubmitPassword: Bool {
        loginMethod == nil && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func startLogin(_ method: LoginMethod) {
        guard loginMethod == nil, method != .password || canSubmitPassword else { return }
        focusedField = nil
        loginMethod = method
        appState.authError = nil
        Task {
            defer { loginMethod = nil }
            switch method {
            case .password:
                await appState.login(serverURL: AppState.defaultServerURL, email: email, password: password)
            case .feishu:
                do {
                    let token = try await oauthLogin.authenticateWithFeishu(serverURL: AppState.defaultServerURL)
                    await appState.completeOAuthLogin(serverURL: AppState.defaultServerURL, token: token)
                } catch OAuthLoginError.cancelled {
                    // The user can immediately choose either sign-in method again.
                } catch {
                    appState.authError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ServiceEntryView()
        .environment(AppState())
}
