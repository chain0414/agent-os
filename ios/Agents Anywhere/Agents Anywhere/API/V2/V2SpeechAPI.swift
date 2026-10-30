import Foundation

protocol V2SpeechAPIProtocol {
    func credentials() async throws -> V2SpeechCredentials
}

struct V2SpeechAPI: V2SpeechAPIProtocol {
    let transport: any HTTPTransport

    func credentials() async throws -> V2SpeechCredentials {
        do {
            return try await transport.send(HTTPRequest<EmptyRequestBody, V2SpeechCredentials>(
                method: .post, path: "/speech/credentials"
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Upstream response text must never reach alerts, logs or persistence.
            if let failure = error as? HTTPError {
                if case .unauthorized = failure { throw ComposerSpeechFailure.authenticationFailed }
                switch failure.statusCode {
                case 401, 403: throw ComposerSpeechFailure.authenticationFailed
                case 429: throw ComposerSpeechFailure.rateLimited
                default: throw ComposerSpeechFailure.serviceUnavailable
                }
            }
            if let failure = error as? URLError {
                if failure.code == .cancelled { throw CancellationError() }
                throw ComposerSpeechFailure.networkUnavailable
            }
            throw ComposerSpeechFailure.serviceUnavailable
        }
    }
}
