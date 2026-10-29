import Foundation
import Observation

nonisolated enum ComposerSpeechEvent: Sendable {
    case downloadingModel
    case recording
    case transcript(text: String, start: Double, end: Double, isFinal: Bool)
    case failed(ComposerSpeechFailure)
}

nonisolated enum ComposerSpeechFailure: Error, Sendable {
    case microphoneDenied, unsupportedLanguage, unavailable, modelDownload
    case audioUnavailable, recognitionFailed, interrupted, noSpeech

    var message: String {
        switch self {
        case .microphoneDenied: String(localized: "请在系统设置中允许麦克风访问后重试。")
        case .unsupportedLanguage: String(localized: "当前输入语言不支持语音识别，请切换键盘语言或使用键盘听写。")
        case .unavailable: String(localized: "此设备暂不支持应用内语音输入，请使用键盘听写。")
        case .modelDownload: String(localized: "语音模型未能准备好，请联网后重试。")
        case .audioUnavailable: String(localized: "麦克风暂不可用，请检查音频设备后重试。")
        case .recognitionFailed: String(localized: "语音识别失败，已保留识别出的文字，请重试。")
        case .interrupted: String(localized: "录音已中断，已保留识别出的文字。")
        case .noSpeech: String(localized: "没有识别到语音，请重试。")
        }
    }
}

@MainActor protocol ComposerSpeechRecognizing: AnyObject {
    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws
    func finish() async throws
    /// Stops microphone capture synchronously, including during preparation.
    func cancel()
}

/// Owns one recording's draft snapshot. Speech never invokes a send action.
@MainActor @Observable final class ComposerVoiceInput {
    enum Phase { case idle, preparing, downloadingModel, recording, finishing }
    private(set) var phase: Phase = .idle
    var error: ComposerSpeechFailure?
    var isActive: Bool { phase != .idle }

    @ObservationIgnored private let recognizer: any ComposerSpeechRecognizing
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private weak var draft: ComposerDraft?
    @ObservationIgnored private var originalText = ""
    @ObservationIgnored private var lastAppliedText = ""
    @ObservationIgnored private var prefix = ""
    @ObservationIgnored private var suffix = ""
    @ObservationIgnored private var segments: [Segment] = []

    private struct Segment {
        let text: String
        let start: Double, end: Double
        let isFinal: Bool
        func overlaps(_ other: Segment) -> Bool { start < other.end && other.start < end }
    }

    init(recognizer: any ComposerSpeechRecognizing) { self.recognizer = recognizer }

    func start(draft: ComposerDraft, locale: Locale, selection: NSRange? = nil) {
        guard !isActive, draft.isValid, !draft.isComposing, !draft.isVoiceInputActive else { return }
        generation += 1
        let current = generation
        self.draft = draft
        originalText = draft.text; lastAppliedText = draft.text
        if let selection, let range = Range(selection, in: draft.text) {
            prefix = String(draft.text[..<range.lowerBound]); suffix = String(draft.text[range.upperBound...])
        } else {
            prefix = draft.text; suffix = ""
        }
        segments = []; error = nil; phase = .preparing
        draft.isVoiceInputActive = true
        operation = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == current, isActive else { return }
            do {
                try await recognizer.start(locale: locale) { [weak self] event in
                    self?.receive(event, generation: current)
                }
            } catch {
                guard generation == current, isActive else { return }
                complete(error: (error as? ComposerSpeechFailure) ?? .recognitionFailed)
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        phase = .finishing
        let current = generation
        operation = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == current, isActive else { return }
            do {
                try await recognizer.finish()
                guard generation == current, isActive else { return }
                complete(error: segments.isEmpty ? .noSpeech : nil)
            } catch {
                guard generation == current, isActive else { return }
                complete(error: (error as? ComposerSpeechFailure) ?? .recognitionFailed)
            }
        }
    }

    func cancel() { end(restoreOriginal: true) }

    /// Leaving the page/backgrounding keeps the already visible transcription.
    func interrupt() { end(restoreOriginal: false) }

    func waitUntilSettled() async { await operation?.value }

    private func receive(_ event: ComposerSpeechEvent, generation current: Int) {
        guard generation == current, isActive else { return }
        guard let draft, draft.isValid, draft.text == lastAppliedText else {
            interrupt(); return
        }
        switch event {
        case .downloadingModel:
            if phase == .preparing { phase = .downloadingModel }
        case .recording:
            if phase == .preparing || phase == .downloadingModel { phase = .recording }
        case let .transcript(text, start, end, isFinal):
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let next = Segment(text: text, start: start, end: end, isFinal: isFinal)
            // A late volatile result cannot roll back a finalized time range.
            if !isFinal, segments.contains(where: { $0.isFinal && $0.overlaps(next) }) { return }
            segments.removeAll { $0.overlaps(next) }
            segments.append(next); segments.sort { $0.start < $1.start }
            lastAppliedText = prefix + segments.map(\.text).joined() + suffix
            draft.text = lastAppliedText
        case let .failed(error): complete(error: error)
        }
    }

    private func complete(error: ComposerSpeechFailure?) {
        self.error = error
        end(restoreOriginal: false)
    }

    private func end(restoreOriginal: Bool) {
        guard isActive else { return }
        generation += 1
        operation?.cancel()
        recognizer.cancel()
        if let draft {
            if restoreOriginal, draft.isValid, draft.text == lastAppliedText { draft.text = originalText }
            draft.isVoiceInputActive = false
        }
        phase = .idle
        self.draft = nil
        segments = []
    }
}
