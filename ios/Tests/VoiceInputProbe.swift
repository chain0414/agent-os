// Disposable simulator harness. Only ASR events and attachment/symbol dependencies
// are synthetic; ChatComposer, its layout and the native text editor are real.
import SwiftUI
import UIKit

nonisolated struct V2AttachmentReference: Codable, Equatable {}
nonisolated struct V2LocalAttachment {
    init(fileId: String, name: String, mediaType: String, data: Data, sha256: String?) {}
}
struct ChatComposerAttachment: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void
    var body: some View { Text(attachment.name) }
}
struct AppSymbol: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat = 20) { self.name = name; self.size = size }
    var body: some View { Image(systemName: name).font(.system(size: size)) }
}

@MainActor final class ProbeSpeechRecognizer: ComposerSpeechRecognizing {
    var callback: (@MainActor (ComposerSpeechEvent) -> Void)?
    var scenario = "idle"
    var pending: CheckedContinuation<Void, Never>?
    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        callback = onEvent
        if scenario == "preparing" {
            await withCheckedContinuation { pending = $0 }
            return
        }
        onEvent(.recording)
        if scenario != "empty-recording" {
            onEvent(.transcript(text: "请检查登录页面，保留深色主题。", start: 0, end: 3, isFinal: false))
        }
    }
    func finish() async throws {
        if scenario == "finishing" || scenario == "send-finishing" {
            await withCheckedContinuation { pending = $0 }
        }
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        switch scenario {
        case "final-failure": throw ComposerSpeechFailure.recognitionFailed
        case "no-speech": callback?(.clearTranscript)
        default:
            callback?(.transcript(text: "请修复登录页面的输入校验，保留深色主题并补充回归测试。", start: 0, end: 4, isFinal: true))
        }
    }
    func cancel() { pending?.resume(); pending = nil; callback = nil }
}

@main struct VoiceInputProbeApp: App {
    var body: some Scene { WindowGroup { VoiceInputProbeView() } }
}

@MainActor struct VoiceInputProbeView: View {
    private let scenario: String
    @State private var draft = ComposerDraft()
    @State private var editor = ComposerEditorController()
    @State private var engine = ProbeSpeechRecognizer()
    @State private var voice: ComposerVoiceInput
    @State private var sendCount = 0
    @State private var stopCount = 0
    @State private var lastSentText: String?

    init() {
        let scenario = ProcessInfo.processInfo.arguments.last ?? "idle"
        self.scenario = scenario
        let engine = ProbeSpeechRecognizer(); engine.scenario = scenario
        _engine = State(initialValue: engine)
        _voice = State(initialValue: ComposerVoiceInput(recognizer: engine))
    }

    var body: some View {
        VStack {
            Text("合成语音输入案例：\(scenario)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("已发送：\(sendCount)")
                .accessibilityIdentifier("voice.probe.sendCount")
            Text("已停止生成：\(stopCount)")
                .accessibilityIdentifier("voice.probe.stopCount")
            Text(verbatim: lastSentText ?? "尚未发送文字")
                .accessibilityIdentifier("voice.probe.sentText")
            ChatComposer(draft: draft, editor: editor, isStreaming: scenario == "running-recording",
                canSend: scenario != "disabled-target",
                maximumEditorHeight: 160, controls: ChatControlMetrics(bodyLineHeight: scenario == "large" ? 40 : 22),
                onSend: {
                    let sendingDraft = draft
                    Task { @MainActor in
                        guard let text = await editor.committedTextForSend(),
                              draft === sendingDraft, sendingDraft.isValid else { return }
                        lastSentText = text
                        sendCount += 1
                    }
                }, onStop: { stopCount += 1 }, onOptions: {},
                showsCommands: true, voice: voice)
                .frame(maxWidth: scenario == "narrow" ? 320 : .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.dynamicTypeSize, scenario == "large" ? .accessibility2 : .large)
        .task {
            switch scenario {
            case "recording", "finishing", "preparing", "large", "narrow", "final-revision", "final-failure", "no-speech",
                 "send-finishing", "empty-recording", "disabled-target", "running-recording":
                draft.text = scenario == "empty-recording" ? "" : "原稿："
                voice.start(draft: draft, locale: Locale(identifier: "zh-CN"))
                await voice.waitUntilSettled()
                if scenario == "finishing" { voice.finish() }
            case "error": voice.error = .microphoneDenied
            default: break
            }
        }
    }
}
