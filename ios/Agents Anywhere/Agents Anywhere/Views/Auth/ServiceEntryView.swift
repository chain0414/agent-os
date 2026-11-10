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
        VStack(spacing: 8) {
            AuthPrimaryButton(
                title: String(localized: "Log In"),
                isLoading: loginMethod == .password,
                disabled: loginMethod != nil,
            ) {
                startLogin(.password)
            }
            .accessibilityIdentifier("auth.sign-in")

            Button {
                startLogin(.feishu)
            } label: {
                Text("Sign in with Feishu")
                    .opacity(loginMethod == .feishu ? 0 : 1)
                    .overlay {
                        if loginMethod == .feishu {
                            ProgressView()
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loginMethod != nil)
            .accessibilityLabel(Text("Sign in with Feishu"))
            .accessibilityIdentifier("auth.feishu")
        }
    }

    private var missingField: Field? {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .email }
        return password.isEmpty ? .password : nil
    }

    private func startLogin(_ method: LoginMethod) {
        guard loginMethod == nil else { return }
        if method == .password, let missingField {
            focusedField = missingField
            return
        }
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
