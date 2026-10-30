import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct ComposerVoiceInputTests {
    @Test func sendDuringRecordingWaitsForFinalWords() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "请修改", start: 0, end: 1, isFinal: false))
        let send = Task { await voice.finishForSend(draft: draft) }
        await engine.waitForFinish()
        #expect(voice.phase == .finishing && !draft.canAttemptSend)
        engine.emit(.transcript(text: "请修改登录页。", start: 0, end: 2, isFinal: true))
        engine.completeFinish()
        #expect(await send.value == "请修改登录页。")
        #expect(draft.canAttemptSend && engine.finishCount == 1)
        #expect(await voice.finishForSend(draft: draft) == nil)
    }

    @Test func sendBeforeFirstTranscriptStillCollectsFinalResult() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        let send = Task { await voice.finishForSend(draft: draft) }
        await engine.waitForFinish()
        engine.emit(.transcript(text: "稍后返回的文字。", start: 0, end: 2, isFinal: true))
        engine.completeFinish()
        #expect(await send.value == "稍后返回的文字。")
    }

    @Test func canceledOrFailedFinalizationDoesNotAuthorizeSend() async {
        for failure in [false, true] {
            let engine = FakeComposerSpeechRecognizer()
            let voice = ComposerVoiceInput(recognizer: engine)
            let draft = ComposerDraft(); draft.text = "原稿"
            voice.start(draft: draft, locale: .current)
            await engine.waitForStart()
            engine.emit(.transcript(text: "部分转写", start: 0, end: 1, isFinal: false))
            let send = Task { await voice.finishForSend(draft: draft) }
            await engine.waitForFinish()
            if failure { engine.emit(.failed(.networkUnavailable)) } else { voice.cancel() }
            #expect(await send.value == nil)
            #expect(draft.text == (failure ? "原稿部分转写" : "原稿"))
        }
    }

    @Test func emptyFinalCannotSendExistingDraft() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "原稿"
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        let send = Task { await voice.finishForSend(draft: draft) }
        await engine.waitForFinish()
        engine.completeFinish()
        #expect(await send.value == nil)
        #expect(draft.text == "原稿" && voice.error == .noSpeech)
    }

    @Test func changedDraftAndCanceledSendTaskCannotSend() async {
        for cancelTask in [false, true] {
            let engine = FakeComposerSpeechRecognizer()
            let voice = ComposerVoiceInput(recognizer: engine)
            let draft = ComposerDraft()
            voice.start(draft: draft, locale: .current)
            await engine.waitForStart()
            engine.emit(.transcript(text: "部分转写", start: 0, end: 1, isFinal: false))
            let send = Task { await voice.finishForSend(draft: draft) }
            await engine.waitForFinish()
            if cancelTask { send.cancel() } else { draft.invalidate() }
            engine.completeFinish()
            #expect(await send.value == nil)
        }
    }

    @Test func secondSendRequestCannotJoinPendingFinalization() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "最终文字", start: 0, end: 1, isFinal: true))
        let send = Task { await voice.finishForSend(draft: draft) }
        await engine.waitForFinish()
        #expect(await voice.finishForSend(draft: draft) == nil)
        engine.completeFinish()
        #expect(await send.value == "最终文字")
        #expect(engine.finishCount == 1)
    }

    @Test func retractedCloudTranscriptRestoresOriginalSelectionAndReportsNoSpeech() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "保留选中的原文"
        voice.start(draft: draft, locale: .current, selection: NSRange(location: 0, length: 3))
        await engine.waitForStart()
        engine.emit(.transcript(text: "误识别", start: 0, end: 1, isFinal: false))
        engine.emit(.clearTranscript)
        #expect(draft.text == "保留选中的原文")
        #expect(draft.isVoiceInputActive && !draft.canAttemptSend)
        voice.finish()
        await engine.waitForFinish()
        engine.completeFinish()
        await voice.waitUntilSettled()
        #expect(draft.text == "保留选中的原文" && voice.error == .noSpeech)
    }

    @Test func cancellationBeforeStartTaskRunsDoesNotCallRecognizer() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        voice.cancel()
        await voice.waitUntilSettled()
        #expect(engine.startCount == 0)
        #expect(!draft.isVoiceInputActive)
    }

    @Test func interimResultsReplaceRatherThanRepeatAndSendWaitsForConfirmation() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "原稿 "
        voice.start(draft: draft, locale: Locale(identifier: "zh-CN"))
        await engine.waitForStart()
        #expect(draft.isVoiceInputActive && !draft.canAttemptSend)
        engine.emit(.transcript(text: "请修改", start: 0, end: 1, isFinal: false))
        engine.emit(.transcript(text: "请修改登录页。", start: 0, end: 2, isFinal: true))
        engine.emit(.transcript(text: "保留主题。", start: 2, end: 3, isFinal: false))
        #expect(draft.text == "原稿 请修改登录页。保留主题。")
        voice.finish()
        await engine.waitForFinish()
        engine.emit(.transcript(text: "保留深色主题。", start: 2, end: 4, isFinal: true))
        #expect(!draft.canAttemptSend)
        engine.completeFinish()
        await voice.waitUntilSettled()
        #expect(draft.text == "原稿 请修改登录页。保留深色主题。")
        #expect(draft.canAttemptSend && voice.phase == .idle)
        #expect(engine.finishCount == 1)
    }

    @Test func cancelRestoresOriginalDraftAndAttachmentAndRejectsLateEvents() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "保留原文"
        let attachment = ChatAttachment(name: "sample.txt", data: Data([1]), mediaType: "text/plain")
        draft.attachments = [attachment]
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "要取消的内容", start: 0, end: 1, isFinal: false))
        voice.cancel()
        engine.emit(.recording)
        engine.emit(.transcript(text: "迟到的内容", start: 0, end: 1, isFinal: true))
        #expect(draft.text == "保留原文" && draft.attachments == [attachment])
        #expect(voice.phase == .idle && !draft.isVoiceInputActive)
        #expect(engine.cancelCount > 0)
    }

    @Test func cancellationWhilePermissionIsPendingNeverRestartsRecording() async {
        let engine = FakeComposerSpeechRecognizer(); engine.holdStart = true
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "原稿"
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        voice.cancel()
        engine.completeStart()
        await voice.waitUntilSettled()
        engine.emit(.recording)
        #expect(voice.phase == .idle && draft.text == "原稿")
        #expect(!draft.isVoiceInputActive)
    }

    @Test func markedTextAndInvalidDraftCannotStart() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "nihao"; draft.isComposing = true
        voice.start(draft: draft, locale: .current)
        #expect(voice.phase == .idle && engine.startCount == 0)
        draft.invalidate()
        voice.start(draft: draft, locale: .current)
        #expect(voice.phase == .idle && engine.startCount == 0)
    }

    @Test func selectionReplacementUsesUTF16AndPreservesSurroundingUnicode() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "👩🏽‍💻把旧内容改好"
        let selection = (draft.text as NSString).range(of: "旧内容")
        voice.start(draft: draft, locale: .current, selection: selection)
        await engine.waitForStart()
        engine.emit(.transcript(text: "登录页", start: 0, end: 1, isFinal: true))
        #expect(draft.text == "👩🏽‍💻把登录页改好")
        voice.cancel()
        #expect(draft.text == "👩🏽‍💻把旧内容改好")
    }

    @Test func interruptionPreservesLatestTextButCancelDoesNotOverwriteNewerEdits() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "已经说出的文字", start: 0, end: 1, isFinal: true))
        voice.interrupt()
        #expect(draft.text == "已经说出的文字" && draft.canAttemptSend)
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart(count: 2)
        engine.emit(.transcript(text: "新录音", start: 0, end: 1, isFinal: false))
        draft.text = "另一处修改的草稿"
        engine.emit(.transcript(text: "迟到更新", start: 0, end: 2, isFinal: true))
        voice.cancel()
        #expect(draft.text == "另一处修改的草稿")
    }

    @Test func oldSessionCallbacksCannotUpdateAnotherDraftOrRestartNewRecording() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let first = ComposerDraft(); first.text = "第一份"
        voice.start(draft: first, locale: .current)
        await engine.waitForStart()
        let oldCallback = engine.callback
        voice.interrupt()
        let second = ComposerDraft(); second.text = "第二份"
        voice.start(draft: second, locale: .current)
        await engine.waitForStart(count: 2)
        oldCallback?(.failed(.recognitionFailed))
        oldCallback?(.transcript(text: "旧结果", start: 0, end: 1, isFinal: true))
        #expect(second.text == "第二份" && second.isVoiceInputActive)
        first.invalidate()
        oldCallback?(.recording)
        #expect(first.text.isEmpty)
        voice.cancel()
    }

    @Test func outOfOrderAndRepeatedFinalSegmentsRemainOrderedAndStable() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "第二句。", start: 2, end: 4, isFinal: true))
        engine.emit(.transcript(text: "第一句。", start: 0, end: 2, isFinal: true))
        engine.emit(.transcript(text: "第一句。", start: 0, end: 2, isFinal: true))
        engine.emit(.transcript(text: "旧暂定结果", start: 0, end: 1, isFinal: false))
        #expect(draft.text == "第一句。第二句。")
        voice.cancel()
    }

    @Test func failedRecognitionRetainsPartialTextAndAllowsRetry() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "已有 "
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        engine.emit(.transcript(text: "部分文字", start: 0, end: 1, isFinal: false))
        engine.emit(.failed(.interrupted))
        #expect(voice.error == .interrupted && voice.phase == .idle)
        #expect(draft.text == "已有 部分文字" && draft.canAttemptSend)
        engine.startFailure = .microphoneDenied
        voice.start(draft: draft, locale: .current)
        await voice.waitUntilSettled()
        #expect(voice.error == .microphoneDenied && draft.text == "已有 部分文字")
        #expect(!draft.isVoiceInputActive)
    }

    @Test func finishingWithoutSpeechPreservesSelectedTextAndReportsNoSpeech() async {
        let engine = FakeComposerSpeechRecognizer()
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft(); draft.text = "不删除选中的原文"
        voice.start(draft: draft, locale: .current, selection: NSRange(location: 0, length: 3))
        await engine.waitForStart()
        engine.emit(.transcript(text: " \n", start: 0, end: 1, isFinal: true))
        voice.finish()
        await engine.waitForFinish()
        engine.completeFinish()
        await voice.waitUntilSettled()
        #expect(draft.text == "不删除选中的原文" && voice.error == .noSpeech)
        #expect(!draft.isVoiceInputActive)
    }

    @Test func cancelBeforeFinishTaskRunsNeverFinishesAnotherRecording() async {
        let engine = FakeComposerSpeechRecognizer()
        engine.finishImmediately = true
        let voice = ComposerVoiceInput(recognizer: engine)
        let draft = ComposerDraft()
        voice.start(draft: draft, locale: .current)
        await engine.waitForStart()
        voice.finish()
        voice.cancel()
        await voice.waitUntilSettled()
        #expect(engine.finishCount == 0)
    }
}

@MainActor private final class FakeComposerSpeechRecognizer: ComposerSpeechRecognizing {
    var callback: (@MainActor (ComposerSpeechEvent) -> Void)?
    var startCount = 0, finishCount = 0, cancelCount = 0
    var holdStart = false
    var finishImmediately = false
    var startFailure: ComposerSpeechFailure?
    private var startGate: CheckedContinuation<Void, Never>?
    private var finishGate: CheckedContinuation<Void, Never>?
    private var started: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishing: CheckedContinuation<Void, Never>?

    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        startCount += 1; callback = onEvent
        for (count, gate) in started where count <= startCount { gate.resume() }
        started.removeAll { $0.0 <= startCount }
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        if let startFailure { throw startFailure }
        onEvent(.recording)
    }
    func finish() async throws {
        finishCount += 1
        if finishImmediately { return }
        await withCheckedContinuation { gate in
            finishGate = gate
            finishing?.resume(); finishing = nil
        }
    }
    func cancel() { cancelCount += 1; completeFinish() }
    func emit(_ event: ComposerSpeechEvent) { callback?(event) }
    func completeStart() { startGate?.resume(); startGate = nil }
    func completeFinish() { finishGate?.resume(); finishGate = nil }
    func waitForStart(count: Int = 1) async {
        if startCount >= count { return }
        await withCheckedContinuation { started.append((count, $0)) }
    }
    func waitForFinish() async {
        if finishCount > 0 { return }
        await withCheckedContinuation { finishing = $0 }
    }
}
