import SwiftUI
import UIKit

struct ChatComposer: View {
    @Bindable var draft: ComposerDraft
    let editor: ComposerEditorController
    let isStreaming: Bool
    var canSend = true
    var canStop = true
    var isBusy = false
    var placeholder = String(localized: "询问 Agents")
    let maximumEditorHeight: CGFloat
    let controls: ChatControlMetrics
    let onSend: () -> Void
    let onStop: () -> Void
    let onOptions: () -> Void
    /// Shown beside send when the session's runtime offers slash commands.
    var showsCommands = false
    var commandsActive = false
    var onCommands: () -> Void = {}
    /// Reports draft mutations from this subtree only. Persisting the draft
    /// must not make the page root observe the editor's text.
    var onDraftChange: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var glass
    @State var voice: ComposerVoiceInput

    init(draft: ComposerDraft, editor: ComposerEditorController, isStreaming: Bool,
         canSend: Bool = true, canStop: Bool = true, isBusy: Bool = false,
         placeholder: String = String(localized: "询问 Agents"),
         maximumEditorHeight: CGFloat, controls: ChatControlMetrics,
         onSend: @escaping () -> Void, onStop: @escaping () -> Void, onOptions: @escaping () -> Void,
         showsCommands: Bool = false, commandsActive: Bool = false,
         onCommands: @escaping () -> Void = {}, onDraftChange: @escaping () -> Void = {},
         credentials: @escaping @MainActor @Sendable () async throws -> V2SpeechCredentials = { throw ComposerSpeechFailure.unavailable },
         voice: ComposerVoiceInput? = nil) {
        _draft = Bindable(wrappedValue: draft)
        self.editor = editor; self.isStreaming = isStreaming
        self.canSend = canSend; self.canStop = canStop; self.isBusy = isBusy
        self.placeholder = placeholder; self.maximumEditorHeight = maximumEditorHeight; self.controls = controls
        self.onSend = onSend; self.onStop = onStop; self.onOptions = onOptions
        self.showsCommands = showsCommands; self.commandsActive = commandsActive
        self.onCommands = onCommands; self.onDraftChange = onDraftChange
        _voice = State(initialValue: voice ?? ComposerVoiceInput(recognizer: ComposerSpeechRecognizer(credentials: credentials)))
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                if !draft.attachments.isEmpty { attachmentTray.disabled(voice.isActive) }
                if voice.isActive { voiceStatus }
                ComposerLayout(expanded: draft.isExpanded, maximumEditorHeight: maximumEditorHeight, controls: controls) {
                    Button(action: onOptions) {
                        AppSymbol("plus", size: 24)
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.isActive)
                    .accessibilityLabel(String(localized: "附件与对话选项"))
                    .accessibilityIdentifier("chat.composer.options")

                    ZStack(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                        NativeComposerEditor(draft: draft, controller: editor, maximumHeight: maximumEditorHeight, onCommandSend: sendIfReady)
                    }

                    Button(action: isStreaming ? onStop : sendIfReady) {
                        AppSymbol(isStreaming ? "stop.fill" : "arrow.up", size: isStreaming ? 13 : 18)
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(AppTheme.primaryControlForeground(colorScheme))
                            .frame(width: controls.sendDiameter, height: controls.sendDiameter)
                            .background(AppTheme.primaryControlBackground(colorScheme).opacity((isStreaming ? canStop : canSend && draft.canAttemptSend) && !isBusy ? 1 : 0.42), in: Circle())
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || (isStreaming ? !canStop : !canSend || !draft.canAttemptSend))
                    .accessibilityLabel(isStreaming ? String(localized: "停止生成") : String(localized: "发送消息"))
                    .accessibilityHint(draft.isComposing ? String(localized: "请先确认输入法候选文字") : "")
                    .accessibilityIdentifier("chat.composer.send")

                    Button(action: toggleVoice) {
                        Image(systemName: voice.phase == .recording ? "stop.circle.fill" : "mic")
                            .font(.system(size: 20))
                            .foregroundStyle(voice.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.isActive ? voice.phase != .recording : isBusy || !draft.isValid || draft.isComposing)
                    .accessibilityLabel(voice.phase == .recording ? String(localized: "结束录音") : String(localized: "语音输入"))
                    .accessibilityHint(String(localized: "转成文字后，确认再发送。"))
                    .accessibilityIdentifier("chat.composer.voice")

                    if showsCommands {
                        Button(action: onCommands) {
                            AppSymbol("command", size: 18)
                                .foregroundStyle(commandsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: controls.touchTarget, height: controls.touchTarget)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(voice.isActive)
                        .accessibilityLabel(String(localized: "指令"))
                        .accessibilityAddTraits(commandsActive ? .isSelected : [])
                        .accessibilityIdentifier("chat.composer.commands")
                    }
                }
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: draft.isExpanded ? controls.expandedCornerRadius : controls.collapsedCornerRadius))
            .glassEffectID("composer", in: glass)
        }
        .padding(.horizontal, draft.isExpanded ? ChatControlMetrics.expandedHorizontalInset : ChatControlMetrics.collapsedHorizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: draft.isExpanded)
        // The composer is the only subtree that already re-evaluates on every
        // keystroke, including each Chinese IME marked-text update. Observing
        // the draft from the page root re-evaluated the whole conversation.
        .onChange(of: draft.text) { _, _ in onDraftChange() }
        .onChange(of: draft.attachments) { _, _ in onDraftChange() }
        .onChange(of: ObjectIdentifier(draft)) { _, _ in voice.interrupt() }
        .onChange(of: draft.isValid) { _, valid in if !valid { voice.interrupt() } }
        .onChange(of: draft.isVoiceInputActive) { _, active in if !active { voice.interrupt() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { voice.interrupt() } }
        .onDisappear { voice.interrupt() }
        .alert(String(localized: "语音输入"), isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            if voice.error == .microphoneDenied {
                Button(String(localized: "打开设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button(String(localized: "好"), role: .cancel) { voice.error = nil }
        } message: { Text(voice.error?.message ?? "") }
    }

    private func sendIfReady() {
        guard !voice.isActive, !draft.isVoiceInputActive else { return }
        onSend()
    }

    private func toggleVoice() {
        if voice.phase == .recording { voice.finish(); return }
        guard !voice.isActive, !draft.isComposing else { return }
        // Keep the selection before dismissing the editor. The cloud service
        // recognizes Chinese and English independently of the keyboard locale.
        let selection = editor.textView?.selectedRange
        editor.finishEditing()
        voice.start(draft: draft, locale: Locale(identifier: "zh-CN"), selection: selection)
    }

    private var voiceStatus: some View {
        HStack(spacing: 8) {
            if voice.phase != .recording { ProgressView().controlSize(.small) }
            Text(voiceStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.composer.voice.status")
            Spacer(minLength: 4)
            Button(String(localized: "取消录音")) { voice.cancel() }
                .font(.footnote)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.composer.voice.cancel")
        }
        .padding(.horizontal, controls.textInset)
        .accessibilityElement(children: .contain)
    }

    private var voiceStatusText: String {
        switch voice.phase {
        case .idle: ""
        case .preparing: String(localized: "正在准备语音输入…")
        case .recording: String(localized: "正在录音…")
        case .finishing: String(localized: "正在完成转写…")
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    ChatComposerAttachment(attachment: attachment) {
                        draft.attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}
