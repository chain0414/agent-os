import SwiftUI

struct ServiceEntryView: View {
    private enum LoginMethod {
        case password, feishu
    }

    @Environment(AppState.self) private var appState
    @StateObject private var oauthLogin = OAuthLoginCoordinator()
    @State private var showsPrivacyPolicy = false
    @State private var email = ""
    @State private var password = ""
    @State private var loginMethod: LoginMethod?

    var body: some View {
        NavigationStack {
            ScrollView {
                AuthWelcomeLayout {
                    AuthBrandLockup()
                    VStack(spacing: 12) {
                        TextField(String(localized: "Email"), text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(loginMethod != nil)
                            .accessibilityIdentifier("auth.email")
                        SecureField(String(localized: "Password"), text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { startLogin(.password) }
                            .disabled(loginMethod != nil)
                            .accessibilityIdentifier("auth.password")
                        AuthPrimaryButton(
                            title: String(localized: "Log In"),
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
                        .accessibilityIdentifier("auth.feishu")
                    }
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 340)

                    if let error = appState.authError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                            .accessibilityIdentifier("auth.error")
                    }
                }
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .navigationTitle("")
            .safeAreaInset(edge: .bottom) {
                Button(String(localized: "privacyPolicy.title")) { showsPrivacyPolicy = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 24)
                    .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicySheet()
        }
    }

    private var canSubmitPassword: Bool {
        loginMethod == nil && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func startLogin(_ method: LoginMethod) {
        guard loginMethod == nil, method != .password || canSubmitPassword else { return }
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
