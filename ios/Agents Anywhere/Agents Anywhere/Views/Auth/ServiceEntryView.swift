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
            VStack(spacing: 22) {
                AAWordmark(fontSize: 36)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                loginCard

                Button("privacyPolicy.title") { showsPrivacyPolicy = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: 384)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicySheet()
        }
    }

    private var loginCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        return VStack(alignment: .leading, spacing: 20) {
            Text("Log In")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 16) {
                loginField("Email", icon: "envelope", field: .email) {
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
                    .accessibilityIdentifier("auth.email")
                }

                loginField("Password", icon: "lock", field: .password) {
                    SecureField("Password", text: $password, prompt: Text(verbatim: ""))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { startLogin(.password) }
                        .accessibilityIdentifier("auth.password")
                }
            }

            if let error = appState.authError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("auth.error")
                }
                .font(.footnote)
            }

            VStack(spacing: 10) {
                loginButton("Log In", method: .password)
                    .disabled(!canSubmitPassword)
                    .accessibilityIdentifier("auth.sign-in")
                loginButton("Sign in with Feishu", method: .feishu)
                    .disabled(loginMethod != nil)
                    .accessibilityIdentifier("auth.feishu")
            }
        }
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        .overlay { shape.strokeBorder(AppTheme.groupedFill(colorScheme)) }
    }

    private func loginField(
        _ title: LocalizedStringKey,
        icon: String,
        field: Field,
        @ViewBuilder input: () -> some View
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let isFocused = focusedField == field

        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                input()
                    .font(.body)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Text(title))
                    .focused($focusedField, equals: field)
                    .tint(SignInButtonStyle.accent(colorScheme))
                    .disabled(loginMethod != nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: shape)
            .overlay {
                shape.strokeBorder(
                    isFocused ? SignInButtonStyle.accent(colorScheme) : SignInButtonStyle.border(colorScheme),
                    lineWidth: isFocused ? 2 : 1
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func loginButton(_ title: LocalizedStringKey, method: LoginMethod) -> some View {
        let isLoading = loginMethod == method
        return Button {
            startLogin(method)
        } label: {
            Text(title)
                .opacity(isLoading ? 0 : 1)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .tint(method == .password ? SignInButtonStyle.accentText(colorScheme) : .secondary)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(Text(title))
        .buttonStyle(SignInButtonStyle(isPrimary: method == .password, isLoading: isLoading))
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

private struct SignInButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let isLoading: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let usesAccent = isPrimary && (isEnabled || isLoading)

        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(usesAccent ? Self.accentText(colorScheme) : (isEnabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(buttonFill(usesAccent: usesAccent), in: shape)
            .overlay {
                if !isPrimary {
                    shape.strokeBorder(Self.border(colorScheme))
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    private func buttonFill(usesAccent: Bool) -> Color {
        if usesAccent { return Self.accent(colorScheme) }
        guard isPrimary else { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.19, green: 0.23, blue: 0.32)
            : Color(red: 0.89, green: 0.92, blue: 0.98)
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.65, green: 0.76, blue: 1) : Color(red: 0.15, green: 0.29, blue: 0.69)
    }

    static func accentText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.06, green: 0.11, blue: 0.23) : .white
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.37) : .black.opacity(0.43)
    }
}

#Preview {
    ServiceEntryView()
        .environment(AppState())
}
