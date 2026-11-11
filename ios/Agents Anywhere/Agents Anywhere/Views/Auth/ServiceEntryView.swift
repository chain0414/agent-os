import SwiftUI

struct ServiceEntryView: View {
    private enum LoginMethod {
        case password, feishu
    }

    private enum Field {
        case email, password
    }

    private enum LoginSheet: Identifiable {
        case methods, privacyPolicy

        var id: Self { self }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var oauthLogin = OAuthLoginCoordinator()
    @State private var loginSheet: LoginSheet?
    @State private var startsFeishuAfterDismiss = false
    @State private var email = ""
    @State private var password = ""
    @State private var loginMethod: LoginMethod?
    @FocusState private var focusedField: Field?
    @ScaledMetric(relativeTo: .body) private var methodsSheetHeight: CGFloat = 188

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
                Button("privacyPolicy.title") { loginSheet = .privacyPolicy }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
        }
        .sheet(item: $loginSheet, onDismiss: startPendingFeishuLogin) { sheet in
            switch sheet {
            case .methods:
                loginMethodsSheet
            case .privacyPolicy:
                PrivacyPolicySheet()
            }
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

            Button {
                focusedField = nil
                loginSheet = .methods
            } label: {
                Text("Other Sign-In Options")
                    .opacity(loginMethod == .feishu ? 0 : 1)
                    .overlay {
                        if loginMethod == .feishu {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .link))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loginMethod != nil || startsFeishuAfterDismiss)
            .accessibilityLabel(Text("Other Sign-In Options"))
            .accessibilityIdentifier("auth.other-methods")
        }
    }

    private var loginMethodsSheet: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Other Sign-In Options")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Button {
                    startsFeishuAfterDismiss = true
                    loginSheet = nil
                } label: {
                    HStack {
                        Text("Sign in with Feishu")
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("auth.feishu")

                Button("返回") { loginSheet = nil }
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .link))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
        }
        .presentationDetents([.height(methodsSheetHeight)])
        .presentationDragIndicator(.visible)
    }

    private func startPendingFeishuLogin() {
        guard startsFeishuAfterDismiss else { return }
        startsFeishuAfterDismiss = false
        startLogin(.feishu)
    }

    private var canSubmitPassword: Bool {
        loginMethod == nil && !startsFeishuAfterDismiss &&
            !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
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
