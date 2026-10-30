import Foundation
import Testing
@testable import ClientCore

@Suite struct AliyunSpeechProtocolTests {
    private let taskID = "448c5cfe-2df5-4f87-828b-5b90a332cb72"

    private func event(_ name: String, task: String? = nil, sentence: [String: Any]? = nil) throws -> Data {
        var payload: [String: Any] = [:]
        if let sentence { payload["output"] = ["sentence": sentence] }
        return try JSONSerialization.data(withJSONObject: [
            "header": ["event": name, "task_id": task ?? taskID], "payload": payload,
        ])
    }

    private func sentence(_ id: Int, _ text: String, final: Bool = false) -> [String: Any] {
        ["sentence_id": id, "text": text, "sentence_end": final, "begin_time": 0, "end_time": NSNull()]
    }

    @Test func nullableEndTimeAndSentenceReplacementProduceWholeSnapshots() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        #expect(try state.receive(event("task-started")) == .started)
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "修改"))) == .transcript("修改"))
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "修改 Codex。", final: true))) == .transcript("修改 Codex。"))
        #expect(try state.receive(event("result-generated", sentence: sentence(2, "保留"))) == .transcript("修改 Codex。保留"))
        #expect(try state.receive(event("result-generated", sentence: sentence(2, "保留 DSH。", final: true))) == .transcript("修改 Codex。保留 DSH。"))
        #expect(try state.receive(event("task-finished")) == .finished("修改 Codex。保留 DSH。"))
    }

    @Test func lateInterimCannotOverwriteFinalAndSentencesSortByID() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        _ = try state.receive(event("task-started"))
        _ = try state.receive(event("result-generated", sentence: sentence(2, "第二句。", final: true)))
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "第一句。", final: true))) == .transcript("第一句。第二句。"))
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "迟到"))) == nil)
        #expect(try state.receive(event("task-finished")) == .finished("第一句。第二句。"))
        #expect(try state.receive(event("result-generated", sentence: sentence(3, "结束后"))) == nil)
    }

    @Test func emptyFinalRetractsInterimAndEmitsEmptySnapshot() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        _ = try state.receive(event("task-started"))
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "误识别"))) == .transcript("误识别"))
        #expect(try state.receive(event("result-generated", sentence: sentence(1, "", final: true))) == .transcript(""))
        #expect(try state.receive(event("task-finished")) == .finished(""))
    }

    @Test func heartbeatUnknownEventAndOtherTasksDoNotAffectTranscript() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        _ = try state.receive(event("task-started"))
        #expect(try state.receive(event("result-generated", sentence: ["heartbeat": true])) == nil)
        #expect(try state.receive(event("future-event")) == nil)
        #expect(try state.receive(event("result-generated", task: UUID().uuidString, sentence: sentence(1, "其他轮次"))) == nil)
        #expect(try state.receive(event("task-finished")) == .finished(""))
    }

    @Test func malformedActualResultsFailInsteadOfSilentlyDroppingWords() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        _ = try state.receive(event("task-started"))
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) {
            try state.receive(event("result-generated", sentence: ["sentence_id": 1, "sentence_end": false]))
        }
    }

    @Test func foreignAndUnknownEventPayloadShapesAreIgnoredBeforeDecodingResults() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        _ = try state.receive(event("task-started"))
        for header in [
            ["event": "future-event", "task_id": taskID],
            ["event": "result-generated", "task_id": UUID().uuidString],
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["header": header, "payload": ["output": ["sentence": 42]]])
            #expect(try state.receive(data) == nil)
        }
    }

    @Test func resultsBeforeTaskStartedAreRejected() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) {
            try state.receive(event("result-generated", sentence: sentence(1, "抢跑")))
        }
    }

    @Test func taskFailedMapsOnlyKnownCodeAndNeverReturnsServerMessage() throws {
        var state = AliyunSpeechProtocol(taskID: taskID)
        let data = Data("{\"header\":{\"task_id\":\"\(taskID)\",\"event\":\"task-failed\",\"error_code\":\"Throttling.RateQuota\",\"error_message\":\"sensitive upstream detail\"},\"payload\":{}}".utf8)
        #expect(try state.receive(data) == .failed(.rateLimited))
    }

    @Test func requestHasFixedAudioParametersAndNoCredentialInJSON() throws {
        let state = AliyunSpeechProtocol(taskID: taskID)
        let data = try state.runTask(model: "qwen-audio-3.0-asr-flash-streaming", languageHints: ["zh", "en"])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try #require(object["header"] as? [String: String])
        let payload = try #require(object["payload"] as? [String: Any])
        let parameters = try #require(payload["parameters"] as? [String: Any])
        #expect(header["task_id"] == taskID && header["action"] == "run-task")
        #expect(parameters["format"] as? String == "pcm")
        #expect(parameters["sample_rate"] as? Int == 16_000)
        #expect(parameters["language_hints"] as? [String] == ["zh", "en"])
        #expect((parameters["vocabulary"] as? [String: Int])?["Codex"] == 4)
        #expect(object["token"] == nil && payload["token"] == nil)
        let finish = try #require(JSONSerialization.jsonObject(with: state.finishTask()) as? [String: Any])
        #expect((finish["header"] as? [String: String])?["action"] == "finish-task")
    }

    @Test(arguments: [
        "wss://workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
        "wss://workspace.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/inference",
        "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
        "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference",
    ]) func acceptsOfficialEndpoints(_ endpoint: String) throws {
        try validate(endpoint)
    }

    @Test(arguments: [
        "ws://dashscope.aliyuncs.com/api-ws/v1/inference",
        "wss://dashscope.aliyuncs.com.evil.test/api-ws/v1/inference",
        "wss://evil.dashscope.aliyuncs.com/api-ws/v1/inference",
        "wss://a.b.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
        "wss://workspace.cn-hangzhou.maas.aliyuncs.com/api-ws/v1/inference",
        "wss://dashscope.aliyuncs.com:8443/api-ws/v1/inference",
        "wss://user:pass@dashscope.aliyuncs.com/api-ws/v1/inference",
        "wss://dashscope.aliyuncs.com/api-ws/v1/inference?token=bad",
        "wss://dashscope.aliyuncs.com/api-ws/v1/inference#fragment",
        "wss://dashscope.aliyuncs.com/other",
    ]) func rejectsEndpointsThatCouldLeakCredentials(_ endpoint: String) {
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(endpoint) }
    }

    @Test func rejectsExpiredEmptyOrInjectedCredentialsAndUnsupportedSettings() {
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(expiresAt: 999) }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(expiresAt: .infinity) }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(token: "") }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(token: "abc\r\nInjected: true") }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(model: "other") }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(sampleRate: 48_000) }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(maxSeconds: 301) }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(maxSeconds: 0) }
        #expect(throws: AliyunSpeechProtocol.ProtocolError.self) { try validate(languages: ["en"]) }
    }

    private func validate(_ endpoint: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference", token: String = "temporary-test-token", expiresAt: Double = 1_300, model: String = "qwen-audio-3.0-asr-flash-streaming", sampleRate: Int = 16_000, maxSeconds: Int = 300, languages: [String] = ["zh", "en"]) throws {
        try AliyunSpeechProtocol.validateCredentials(provider: "aliyun", model: model, url: #require(URL(string: endpoint)), token: token, expiresAt: expiresAt, languageHints: languages, sampleRate: sampleRate, maxRecordingSeconds: maxSeconds, now: 1_000)
    }
}
