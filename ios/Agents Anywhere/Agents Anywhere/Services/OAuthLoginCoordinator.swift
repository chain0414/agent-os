import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class OAuthLoginCoordinator: NSObject, ObservableObject {
    private let callbackScheme = "agents-anywhere"
    private var session: ASWebAuthenticationSession?
    private var attemptID: UUID?
    private var callback: AsyncResultGate<URL>?
    private var context: OAuthPresentationContext?

    func authenticateWithFeishu(serverURL: URL) async throws -> OAuthTokenResponse {
        guard attemptID == nil else { throw OAuthLoginError.busy }
        try Task.checkCancellation()
        guard let window = activeAnchor() else { throw OAuthLoginError.presentationUnavailable }
        let attempt = UUID()
        attemptID = attempt; context = OAuthPresentationContext(anchor: window)
        defer { if attemptID == attempt { cancel() } }
        let pkce = try PKCEPair()
        let state = try PKCEPair.randomURLSafeString(byteCount: 24)
        let authURL = try feishuURL(serverURL: serverURL, pkce: pkce, state: state)
        let callbackURL = try await callbackURL(for: authURL, attempt: attempt)
        try Task.checkCancellation()
        let code = try OAuthCallback.authorizationCode(callbackURL, expectedState: state)
        let token = try await APIClient(serverURL: serverURL).oauthToken(code: code, codeVerifier: pkce.verifier)
        try Task.checkCancellation()
        guard !token.accessToken.isEmpty else { throw OAuthLoginError.invalidToken }
        return token
    }

    func cancel() {
        callback?.resolve(.failure(CancellationError()))
        callback = nil
        let previous = session; session = nil; attemptID = nil; context = nil
        previous?.cancel()
    }

    private func activeAnchor() -> ASPresentationAnchor? {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow
        #else
        return nil
        #endif
    }

    private func callbackURL(for url: URL, attempt: UUID) async throws -> URL {
        let result = AsyncResultGate<URL>()
        callback = result
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                guard !Task.isCancelled else { result.resolve(.failure(CancellationError())); return }
                let browser = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] url, error in
                    Task { @MainActor in
                        if self?.attemptID == attempt { self?.session = nil }
                    }
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        result.resolve(.failure(OAuthLoginError.cancelled))
                    } else if let error { result.resolve(.failure(error)) }
                    else if let url { result.resolve(.success(url)) }
                    else { result.resolve(.failure(OAuthLoginError.invalidCallback)) }
                }
                browser.presentationContextProvider = context
                browser.prefersEphemeralWebBrowserSession = false
                session = browser
                if !browser.start() {
                    session = nil; result.resolve(.failure(OAuthLoginError.couldNotStart))
                }
            }
        } onCancel: { result.resolve(.failure(CancellationError())) }
    }

    private func feishuURL(serverURL: URL, pkce: PKCEPair, state: String) throws -> URL {
        guard let endpoint = URL(string: v2APIPath("/auth/oauth/mobile/feishu"), relativeTo: serverURL)?.absoluteURL,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthLoginError.invalidAuthorizeURL
        }
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw OAuthLoginError.invalidAuthorizeURL }
        return url
    }
}

/// Retain the actual foreground window for this attempt. There is no fallback
/// window to manufacture if the user leaves the screen during authentication.
@MainActor private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

private struct PKCEPair {
    let verifier: String
    let challenge: String

    init() throws {
        verifier = try Self.randomURLSafeString(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthLoginError.randomGenerationFailed }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
