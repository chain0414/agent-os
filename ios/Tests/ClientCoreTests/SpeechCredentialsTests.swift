import Foundation
import Testing
@testable import ClientCore

@MainActor struct SpeechCredentialsTests {
    @Test func typedAPIMasksServerBodiesAndMapsRecoverableFailures() async throws {
        let transport = TestHTTPTransport()
        let api = V2SpeechAPI(transport: transport)
        let expected: [(Int, ComposerSpeechFailure)] = [
            (401, .authenticationFailed), (403, .authenticationFailed),
            (404, .serviceUnavailable), (429, .rateLimited),
            (502, .serviceUnavailable), (503, .serviceUnavailable),
        ]
        for (status, failure) in expected {
            transport.respond = { _ in throw HTTPError.server(statusCode: status, message: "synthetic-private-upstream-body") }
            await #expect(throws: failure) { try await api.credentials() }
        }
        #expect(transport.calls.allSatisfy { $0.method == .post && $0.path == "/speech/credentials" && $0.body == nil })
        transport.respond = { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await api.credentials() }
    }

    @Test func invalidatedAccountScopeCancelsPendingCredentialsAndRejectsNewRequests() async throws {
        let api = PendingSpeechAPI()
        let service = V2SpeechService(speechAPI: api)
        let fetch = Task { try await service.credentials() }
        try await eventually { api.calls == 1 }
        service.invalidate()
        api.release()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        await #expect(throws: CancellationError.self) { try await service.credentials() }
        #expect(api.calls == 1)
    }

    @Test func injectedAccountCredentialsRespectComposerCancellationAndPreserveDraft() async throws {
        let api = PendingSpeechAPI()
        let service = V2SpeechService(speechAPI: api)
        let recognizer = CredentialSpeechRecognizer { try await service.credentials() }
        let voice = ComposerVoiceInput(recognizer: recognizer)
        let draft = ComposerDraft(); draft.text = "保留草稿"
        voice.start(draft: draft, locale: Locale(identifier: "zh-CN"))
        try await eventually { api.calls == 1 }
        #expect(draft.isVoiceInputActive && !draft.canAttemptSend)
        voice.cancel()
        api.release()
        await voice.waitUntilSettled()
        #expect(voice.phase == .idle && voice.error == nil)
        #expect(draft.text == "保留草稿" && !draft.isVoiceInputActive && draft.canAttemptSend)
        #expect(recognizer.recordings == 0)
    }

    @Test func cancellingVoicePreparationRejectsLateCredentials() async throws {
        let api = PendingSpeechAPI()
        let service = V2SpeechService(speechAPI: api)
        let fetch = Task { try await service.credentials() }
        try await eventually { api.calls == 1 }
        fetch.cancel()
        api.release()
        await #expect(throws: CancellationError.self) { try await fetch.value }
    }
}

@MainActor private final class PendingSpeechAPI: V2SpeechAPIProtocol {
    var calls = 0
    private var gate = TestGate()
    func credentials() async throws -> V2SpeechCredentials {
        calls += 1
        await gate.wait()
        return V2SpeechCredentials(provider: "aliyun", model: "synthetic", websocketUrl: URL(string: "wss://example.test")!,
            token: "synthetic", expiresAt: 1893456000, languageHints: ["zh", "en"], sampleRate: 16000, maxRecordingSeconds: 300)
    }
    func release() { gate.release() }
}

@MainActor private final class CredentialSpeechRecognizer: ComposerSpeechRecognizing {
    let credentials: @MainActor () async throws -> V2SpeechCredentials
    var recordings = 0
    init(credentials: @escaping @MainActor () async throws -> V2SpeechCredentials) { self.credentials = credentials }
    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        _ = try await credentials()
        try Task.checkCancellation()
        recordings += 1
        onEvent(.recording)
    }
    func finish() async throws {}
    func cancel() {}
}
