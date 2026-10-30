import Foundation

/// Account-scoped issuance; credentials are held only by the requesting recording.
@MainActor final class V2SpeechService {
    private let speechAPI: any V2SpeechAPIProtocol
    private var requests: [UUID: Task<V2SpeechCredentials, Error>] = [:]
    private var isValid = true

    init(speechAPI: any V2SpeechAPIProtocol) { self.speechAPI = speechAPI }

    func credentials() async throws -> V2SpeechCredentials {
        try Task.checkCancellation()
        guard isValid else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await speechAPI.credentials() }
        requests[id] = task
        defer { requests[id] = nil }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            guard isValid else { throw CancellationError() }
            return value
        } onCancel: {
            task.cancel()
        }
    }

    func invalidate() {
        isValid = false
        requests.values.forEach { $0.cancel() }
        requests = [:]
    }
}
