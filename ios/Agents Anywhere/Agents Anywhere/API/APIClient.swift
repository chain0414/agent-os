import Foundation

enum APIClientError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(status: Int, detail: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "Enter a valid server URL.")
        case .invalidResponse:
            return String(localized: "The server returned an invalid response.")
        case let .server(_, detail):
            return detail
        case let .decoding(detail):
            return detail
        }
    }
}

struct APIClient {
    let serverURL: URL
    var session: URLSession = Self.authenticationSession
    private static let authenticationSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    init(serverURL: URL) {
        self.serverURL = serverURL.normalizedServerURL()
    }

    func health() async throws -> HealthResponse {
        try await request("/health")
    }

    func authConfig() async throws -> AuthConfig {
        try await request("/auth/config")
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await request(
            "/auth/login",
            method: "POST",
            body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password],
        )
    }

    func loginWithDevKit(config: DevKitAuthConfig, email: String, password: String) async throws -> AuthResponse {
        guard
            let endpoint = URLComponents(string: config.apiUrl),
            endpoint.scheme == "https", endpoint.host != nil,
            endpoint.user == nil, endpoint.password == nil,
            endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
            let url = URL(string: config.apiUrl + "/api/runtime/v1/auth/login"),
            var origin = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        else { throw APIClientError.invalidResponse }

        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let appOrigin = origin.string else { throw APIClientError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.publishableKey, forHTTPHeaderField: "X-DevKit-Key")
        request.setValue(appOrigin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode([
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
        let (data, response) = try await session.data(for: request, delegate: NoAuthRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tokens = try? JSONDecoder().decode(DevKitLoginToken.self, from: data),
              tokens.accessToken.range(of: #"^[A-Za-z0-9._~-]{1,8192}$"#, options: .regularExpression) != nil
        else {
            throw APIClientError.server(status: 401, detail: String(localized: "DevKit sign-in failed."))
        }
        return try await self.request(
            "/auth/devkit/login", method: "POST", body: ["accessToken": tokens.accessToken],
        )
    }

    /// Public, unauthenticated; returns nil when the server has no enabled announcement.
    func announcement() async throws -> PublicAnnouncement? {
        let response: PublicAnnouncementResponse = try await request("/announcement")
        return response.announcement.flatMap { value in
            value.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.publishedDate == nil ? nil : value
        }
    }

    func me(token: String) async throws -> AuthMe {
        try await request("/auth/me", token: token)
    }

    func oauthToken(code: String, codeVerifier: String) async throws -> OAuthTokenResponse {
        guard let url = URL(string: v2APIPath("/oauth/token"), relativeTo: serverURL)?.absoluteURL else {
            throw APIClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: "agents-anywhere-mobile"),
            URLQueryItem(name: "redirect_uri", value: "agents-anywhere://oauth/callback"),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIClientError.server(status: http.statusCode, detail: detail)
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    func requestMobileLogin(payload: MobileLoginPayload, deviceName: String) async throws -> MobileLoginStatusResponse {
        try await request(
            "/auth/mobile-login/request",
            method: "POST",
            body: MobileLoginRequest(
                userId: payload.userId,
                loginToken: payload.loginToken,
                deviceName: deviceName,
            ),
        )
    }

    func mobileLoginStatus(payload: MobileLoginPayload) async throws -> MobileLoginStatusResponse {
        try await request(
            "/auth/mobile-login/status",
            method: "POST",
            body: MobileLoginStatusRequest(loginToken: payload.loginToken),
        )
    }

    func exchangeMobileLogin(payload: MobileLoginPayload) async throws -> MobileLoginExchangeResponse {
        try await request(
            "/auth/mobile-login/exchange",
            method: "POST",
            body: MobileLoginExchangeRequest(
                userId: payload.userId,
                loginToken: payload.loginToken,
            ),
        )
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Encodable? = nil,
        token: String? = nil,
    ) async throws -> Response {
        guard let url = URL(string: v2APIPath(path), relativeTo: serverURL)?.absoluteURL else {
            throw APIClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIClientError.server(status: http.statusCode, detail: detail)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw APIClientError.decoding(error.v2Description)
        }
    }
}

private struct DevKitLoginToken: Decodable {
    let accessToken: String
}

private final class NoAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: Encodable) {
        self.encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private struct EmptyBody: Encodable {}

extension URL {
    func normalizedServerURL() -> URL {
        normalizedV2ServerURL()
    }
}

extension URL {
    static func agentsServer(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIClientError.invalidServerURL }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw APIClientError.invalidServerURL
        }
        return url.normalizedServerURL()
    }
}
