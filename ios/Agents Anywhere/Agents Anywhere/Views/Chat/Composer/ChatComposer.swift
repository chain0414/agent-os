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
    @State private var softwareKeyboardVisible = false
    @State var voice: ComposerVoiceInput
    @State private var voiceSendTask: Task<Void, Never>?
    @State private var isSendingVoice = false

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
                            .background(AppTheme.primaryControlBackground(colorScheme).opacity((isStreaming ? canStop && !isBusy : canSendNow) ? 1 : 0.42), in: Circle())
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isStreaming ? isBusy || !canStop : !canSendNow)
                    .accessibilityLabel(isStreaming ? String(localized: "停止生成") : String(localized: "发送消息"))
                    .accessibilityHint(draft.isComposing ? String(localized: "请先确认输入法候选文字") : "")
                    .accessibilityIdentifier("chat.composer.send")

                    Button(action: toggleVoice) {
                        Image(systemName: "mic")
                            .font(.system(size: 20))
                            .foregroundStyle(voice.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .background {
                                if voice.isActive {
                                    Circle().fill(.tint.opacity(0.14)).frame(width: 30, height: 30)
                                    VoiceInputHalo(diameter: min(44, controls.touchTarget - 4))
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.isActive ? voice.phase != .recording : isBusy || !draft.isValid || draft.isComposing)
                    .accessibilityLabel(String(localized: "语音输入"))
                    .accessibilityValue(voiceAccessibilityValue)
                    .accessibilityAddTraits(voice.isActive ? .isSelected : [])
                    .accessibilityHint(voice.phase == .recording ? String(localized: "再次点按结束录音，也可直接发送。") : String(localized: "转成文字后，确认再发送。"))
                    .accessibilityActions {
                        if voice.isActive { Button(String(localized: "取消录音"), action: cancelVoice) }
                    }
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
                    if softwareKeyboardVisible && draft.isFocused {
                        Button { editor.finishEditing() } label: {
                            Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 20))
                                .frame(width: controls.touchTarget, height: controls.touchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "收起键盘"))
                        .accessibilityIdentifier("chat.composer.dismissKeyboard")
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = editor.textView?.window?.screen else { return }
            softwareKeyboardVisible = frame.height > 0 && frame.minY < screen.bounds.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            softwareKeyboardVisible = false
        }
        .onChange(of: ObjectIdentifier(draft)) { _, _ in interruptVoice() }
        .onChange(of: draft.isValid) { _, valid in if !valid { interruptVoice() } }
        .onChange(of: draft.isVoiceInputActive) { _, active in if !active && voice.isActive { interruptVoice() } }
        .onChange(of: canSend) { _, allowed in if !allowed && isSendingVoice { interruptVoice() } }
        .onChange(of: isBusy) { _, busy in if busy && isSendingVoice { interruptVoice() } }
        .onChange(of: isStreaming) { _, streaming in if streaming && isSendingVoice { interruptVoice() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { interruptVoice() } }
        .onDisappear { interruptVoice() }
        .alert(String(localized: "语音输入"), isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            if voice.error == .microphoneDenied {
                Button(String(localized: "打开设置")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button(String(localized: "好"), role: .cancel) { voice.error = nil }
        } message: { Text(voice.error?.message ?? "") }
    }

    private var canSendNow: Bool {
        !isBusy && !isSendingVoice && canSend && draft.isValid && !draft.isComposing
            && (voice.phase == .recording || (!voice.isActive && draft.canAttemptSend))
    }

    private func sendIfReady() {
        guard !isStreaming, canSendNow else { return }
        guard voice.phase == .recording else { onSend(); return }
        isSendingVoice = true
        let currentDraft = draft
        voiceSendTask = Task { @MainActor in
            defer { isSendingVoice = false; voiceSendTask = nil }
            guard let text = await voice.finishForSend(draft: currentDraft), !Task.isCancelled,
                  editor.prepareVoiceTextForSend(text, draft: currentDraft) else { return }
            onSend()
        }
    }

    private func interruptVoice() {
        voiceSendTask?.cancel()
        voice.interrupt()
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

    private func cancelVoice() {
        voiceSendTask?.cancel()
        voice.cancel()
    }

    private var voiceAccessibilityValue: String {
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

/// Keep the repeating animation local so transcript updates don't drive layout.
private struct VoiceInputHalo: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Group {
            if reduceMotion {
                ring.scaleEffect(0.85).opacity(0.5)
            } else {
                ring
                    .scaleEffect(expanded ? 1 : 0.65)
                    .opacity(expanded ? 0 : 0.85)
                    .animation(.easeOut(duration: 1.35).repeatForever(autoreverses: false), value: expanded)
                    .onAppear { expanded = true }
                    .onDisappear { expanded = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        Circle()
            .stroke(.tint, lineWidth: 2)
            .frame(width: diameter, height: diameter)
    }
}
