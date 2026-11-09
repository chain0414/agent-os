import SwiftUI

struct ServiceEntryView: View {
    @Environment(AppState.self) private var appState
    @State private var showsPrivacyPolicy = false
    var onSignIn: () -> Void = {}
    var onSelfHostedLogin: () -> Void = {}
    var onQRCodeLogin: () -> Void = {}

    var body: some View {
        NavigationStack {
            AuthWelcomeLayout {
                AuthBrandLockup()

                VStack(spacing: 12) {
                    AuthPrimaryButton(title: String(localized: "Log In"), systemImage: "person.crop.circle") {
                        onSignIn()
                    }
                    .accessibilityIdentifier("auth.sign-in")

                    AuthGlassButton(String(localized: "Connect to your self-hosted instance"), systemImage: "server.rack") {
                        onSelfHostedLogin()
                    }

                    AuthGlassButton(String(localized: "QR Code Login"), systemImage: "qrcode.viewfinder") {
                        onQRCodeLogin()
                    }
                }
                .frame(maxWidth: 340)

                if let error = appState.authError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
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
}

#Preview {
    ServiceEntryView()
        .environment(AppState())
}
