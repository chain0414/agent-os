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
        onEvent(.transcript(text: "请检查登录页面，保留深色主题。", start: 0, end: 3, isFinal: false))
    }
    func finish() async throws {
        if scenario == "finishing" { await withCheckedContinuation { pending = $0 } }
    }
    func cancel() { pending?.resume(); pending = nil }
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
            ChatComposer(draft: draft, editor: editor, isStreaming: false,
                canSend: scenario != "empty-new-session" || draft.hasSendableContent,
                maximumEditorHeight: 160, controls: ChatControlMetrics(bodyLineHeight: scenario == "large" ? 40 : 22),
                onSend: { sendCount += 1 }, onStop: {}, onOptions: {},
                showsCommands: true, voice: voice)
                .frame(maxWidth: scenario == "narrow" ? 320 : .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.dynamicTypeSize, scenario == "large" ? .accessibility2 : .large)
        .task {
            switch scenario {
            case "recording", "finishing", "preparing", "large", "narrow":
                draft.text = "原稿："
                voice.start(draft: draft, locale: Locale(identifier: "zh-CN"))
                await voice.waitUntilSettled()
                if scenario == "finishing" { voice.finish() }
            case "error": voice.error = .microphoneDenied
            default: break
            }
        }
    }
}
