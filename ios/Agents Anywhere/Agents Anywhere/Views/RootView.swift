import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var loginEntry: LoginEntry?

    var body: some View {
        Group {
            switch appState.route {
            case .loading:
                Color(uiColor: .systemBackground)
            case .signedOut:
                ServiceEntryView(
                    onSignIn: { loginEntry = .defaultServer },
                    onSelfHostedLogin: { loginEntry = .selfHosted },
                    onQRCodeLogin: { loginEntry = .qrCode },
                )
            case .signedIn:
                ChatShellView()
            }
        }
        .sheet(item: $loginEntry) { entry in
            switch entry {
            case .defaultServer:
                ManualLoginView(appState: appState, mode: .defaultServer, onDashboardRequested: completeSignIn)
            case .selfHosted:
                ManualLoginView(appState: appState, mode: .selfHosted, onDashboardRequested: completeSignIn)
            case .qrCode:
                QRCodeLoginView(appState: appState, onDashboardRequested: completeSignIn)
            }
        }
        .announcementGate(
            server: appState.serverURL,
            route: appState.route,
            blocked: loginEntry != nil
        )
        .overlay(alignment: .top) {
            if appState.route == .signedIn, let error = appState.restoreConnectionError {
                HStack(spacing: 12) {
                    AppSymbol("wifi.exclamationmark")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "暂时无法连接，正在显示本地内容")).font(.footnote.weight(.medium))
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Menu {
                        Button(String(localized: "立即重试"), action: retryServerConnection)
                        Button(String(localized: "返回登录"), action: appState.returnToLogin)
                    } label: { AppSymbol("ellipsis").frame(width: 36, height: 36) }
                }
                .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 20))
                .padding(.horizontal, 22).padding(.top, 70).frame(maxWidth: 540)
            }
        }
        .tint(AppTheme.primaryText(colorScheme))
        .background(AppTheme.appBackground(colorScheme))
    }

    private func completeSignIn() {
        appState.activateSignedInRoute()
        loginEntry = nil
    }

    private func retryServerConnection() {
        Task {
            await appState.retryServerConnection()
        }
    }
}

private enum LoginEntry: Identifiable {
    case defaultServer
    case selfHosted
    case qrCode

    var id: Self { self }
}

#Preview {
    RootView()
        .environment(AppState())
}
