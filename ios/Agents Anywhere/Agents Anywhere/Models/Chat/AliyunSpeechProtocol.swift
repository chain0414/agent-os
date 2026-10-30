import Foundation

/// Pure protocol state: no account token, microphone or networking dependencies.
nonisolated struct AliyunSpeechProtocol: Sendable {
    enum ProtocolError: Error { case invalidCredentials, malformedEvent, invalidSequence }
    enum Failure: Sendable, Equatable { case authentication, rateLimited, serviceUnavailable, recognition }
    enum Event: Sendable, Equatable {
        case started, transcript(String), finished(String), failed(Failure)
    }

    let taskID: String
    private var started = false
    private var ended = false
    private var sentences: [Int: Sentence] = [:]

    init(taskID: String) { self.taskID = taskID }

    static func validateCredentials(
        provider: String, model: String, url: URL, token: String, expiresAt: Double,
        languageHints: [String], sampleRate: Int, maxRecordingSeconds: Int,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        guard provider == "aliyun", model == "qwen-audio-3.0-asr-flash-streaming",
              url.scheme == "wss", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
              url.path == "/api-ws/v1/inference", let host = url.host,
              officialHost(host), !token.isEmpty, token.utf8.count <= 8_192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              expiresAt.isFinite, expiresAt > now, sampleRate == 16_000,
              (1...300).contains(maxRecordingSeconds), languageHints == ["zh", "en"] else {
            throw ProtocolError.invalidCredentials
        }
    }

    private static func officialHost(_ host: String) -> Bool {
        if host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" { return true }
        for suffix in [".cn-beijing.maas.aliyuncs.com", ".ap-southeast-1.maas.aliyuncs.com"] {
            guard host.hasSuffix(suffix) else { continue }
            let workspace = host.dropLast(suffix.count)
            return !workspace.isEmpty && workspace.count <= 63
                && workspace.first != "-" && workspace.last != "-"
                && workspace.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
        return false
    }

    func runTask(model: String, languageHints: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                "parameters": ["format": "pcm", "sample_rate": 16_000, "language_hints": languageHints,
                               "vocabulary": ["Codex": 4, "DSH": 4, "GitHub": 4, "Xcode": 4, "Claude": 4],
                               "heartbeat": true],
                "input": [:] as [String: String],
            ] as [String: Any],
        ])
    }

    func finishTask() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [:] as [String: String]],
        ])
    }

    mutating func receive(_ data: Data) throws -> Event? {
        guard data.count <= 1_048_576 else { throw ProtocolError.malformedEvent }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ProtocolError.malformedEvent }
        guard envelope.header.task_id == taskID, !ended else { return nil }
        switch envelope.header.event {
        case "task-started":
            guard !started else { return nil }
            started = true
            return .started
        case "result-generated":
            guard started else { throw ProtocolError.invalidSequence }
            let message: Message
            do { message = try JSONDecoder().decode(Message.self, from: data) }
            catch { throw ProtocolError.malformedEvent }
            guard let sentence = message.payload?.output?.sentence else { throw ProtocolError.malformedEvent }
            if sentence.heartbeat == true { return nil }
            guard let id = sentence.sentence_id, id > 0, sentence.text != nil,
                  let final = sentence.sentence_end, sentences.count < 10_000 || sentences[id] != nil else {
                throw ProtocolError.malformedEvent
            }
            if sentences[id]?.sentence_end == true && !final { return nil }
            sentences[id] = sentence
            return .transcript(transcript)
        case "task-finished":
            guard started else { throw ProtocolError.invalidSequence }
            ended = true
            return .finished(transcript)
        case "task-failed":
            ended = true
            let code = envelope.header.error_code?.lowercased() ?? ""
            if code.contains("throttl") || code.contains("ratequota") || code.contains("ratelimit") { return .failed(.rateLimited) }
            if code.contains("auth") || code.contains("invalidapikey") || code.contains("accessdenied") { return .failed(.authentication) }
            if code.contains("unavailable") || code.contains("internalerror") { return .failed(.serviceUnavailable) }
            return .failed(.recognition)
        default: return nil
        }
    }

    private var transcript: String { sentences.keys.sorted().compactMap { sentences[$0]?.text }.joined() }

    private struct Envelope: Decodable {
        struct Header: Decodable { let task_id: String; let event: String; let error_code: String? }
        let header: Header
    }

    private struct Message: Decodable {
        struct Payload: Decodable {
            struct Output: Decodable { let sentence: Sentence? }
            let output: Output?
        }
        let payload: Payload?
    }

    private struct Sentence: Decodable, Sendable {
        let sentence_id: Int?
        let text: String?
        let sentence_end: Bool?
        let heartbeat: Bool?
    }
}
