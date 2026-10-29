#if os(iOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Audio stays in memory and is consumed exclusively by Apple's on-device modules.
@MainActor
final class ComposerSpeechRecognizer: ComposerSpeechRecognizing {
    private final class Session {
        var callback: (@MainActor (ComposerSpeechEvent) -> Void)?
        var setupTask: Task<Void, Error>?
        var resultsTask: Task<Void, Error>?
        var finishTask: Task<Void, Error>?
        var cleanupTask: Task<Void, Never>?
        var analyzer: SpeechAnalyzer?
        var engine: AVAudioEngine?
        var input: ComposerSpeechAudioInput?
        var reservedLocale: Locale?
        var installation: AssetInstallationRequest?
        var observers: [NSObjectProtocol] = []
        var tapInstalled = false
        var audioSessionActive = false
        var hasTranscript = false
        var finalization: Finalization?
        var finalizationTimedOut = false

        init(callback: @escaping @MainActor (ComposerSpeechEvent) -> Void) {
            self.callback = callback
        }
    }

    private final class Finalization {
        var continuation: CheckedContinuation<Void, Error>?
        var operation: Task<Void, Never>?
        var timeout: Task<Void, Never>?

        func resolve(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            operation?.cancel()
            timeout = nil
            operation = nil
            continuation.resume(with: result)
        }
    }

    // Every composer creates its own recognizer, but AVAudioSession and model
    // reservations belong to the process. One owner and one cleanup chain cover
    // both active recordings and starts waiting for their predecessor to exit.
    private static weak var owner: ComposerSpeechRecognizer?
    private static var cleanupTail: Task<Void, Never>?
    private var current: Session?

    isolated deinit {
        cancel()
    }

    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        try Task.checkCancellation()
        cancel()
        if let previous = Self.owner, let session = previous.current {
            previous.fail(session, with: .interrupted)
        }
        // Publish the pending session before any suspension so another composer
        // can interrupt it immediately, including while model cleanup is pending.
        let session = Session(callback: onEvent)
        current = session
        Self.owner = self
        let predecessor = Self.cleanupTail
        let setup = Task {
            // Capture the predecessor before this session can create its own
            // cleanup task. Reading the shared tail here could wait on ourselves.
            await predecessor?.value
            try self.requireCurrent(session)
            try await self.prepare(session, locale: locale)
        }
        session.setupTask = setup
        do {
            try await withTaskCancellationHandler {
                try await setup.value
                try Task.checkCancellation()
                try requireCurrent(session)
            } onCancel: {
                setup.cancel()
                Task { @MainActor [weak self] in
                    guard self?.current === session else { return }
                    self?.cancel()
                }
            }
        } catch {
            detach(session)
            await cleanUp(session).value
            if error is CancellationError { throw error }
            throw (error as? ComposerSpeechFailure) ?? .recognitionFailed
        }
    }

    func finish() async throws {
        guard let session = current else { return }
        if let finishing = session.finishTask {
            try await finishing.value
            return
        }
        let finishing = Task { @MainActor in
            try await session.setupTask?.value
            try self.requireCurrent(session)
            self.stopCapture(session)
            await session.input?.finish()
            try self.requireCurrent(session)
            do {
                try await self.finalizeAndDrain(session)
                try self.requireCurrent(session)
                let hasTranscript = session.hasTranscript
                self.detach(session)
                await self.cleanUp(session).value
                if !hasTranscript { throw ComposerSpeechFailure.noSpeech }
            } catch {
                self.detach(session)
                let cleanup = self.cleanUp(session)
                if !session.finalizationTimedOut, !(error is CancellationError) {
                    await cleanup.value
                }
                if error is CancellationError { throw error }
                throw (error as? ComposerSpeechFailure) ?? .recognitionFailed
            }
        }
        session.finishTask = finishing
        try await finishing.value
    }

    func cancel() {
        guard let session = current else { return }
        detach(session)
        session.callback = nil
        session.setupTask?.cancel()
        session.resultsTask?.cancel()
        session.installation?.progress.cancel()
        session.finalization?.resolve(.failure(CancellationError()))
        stopCapture(session)
        session.input?.cancel()
        cleanUp(session)
    }

    private func requireCurrent(_ session: Session) throws {
        try Task.checkCancellation()
        guard current === session, Self.owner === self else { throw CancellationError() }
    }

    private func detach(_ session: Session) {
        guard current === session else { return }
        current = nil
        if Self.owner === self { Self.owner = nil }
    }

    private func finalizeAndDrain(_ session: Session) async throws {
        let finalization = Finalization()
        session.finalization = finalization
        try await withCheckedThrowingContinuation { continuation in
            finalization.continuation = continuation
            finalization.operation = Task { @MainActor in
                do {
                    try await session.analyzer?.finalizeAndFinishThroughEndOfInput()
                    // Finalize can return before the result consumer delivers its last item.
                    try await session.resultsTask?.value
                    try self.requireCurrent(session)
                    finalization.resolve(.success(()))
                } catch {
                    finalization.resolve(.failure(error))
                }
            }
            finalization.timeout = Task { @MainActor [weak self, weak session] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, let session, self.current === session else { return }
                session.finalizationTimedOut = true
                finalization.resolve(.failure(ComposerSpeechFailure.recognitionFailed))
                self.fail(session, with: .recognitionFailed)
            }
        }
    }

    private func prepare(_ session: Session, locale: Locale) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        try requireCurrent(session)
        guard granted else { throw ComposerSpeechFailure.microphoneDenied }

        let module: any SpeechModule
        let selectedLocale: Locale
        let startResults: @MainActor () -> Task<Void, Error>
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           Self.sameLanguage(supported, locale) {
            selectedLocale = supported
            let transcriber = SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription)
            module = transcriber
            startResults = { self.consume(transcriber.results, session: session) { $0.text } }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale),
                  Self.sameLanguage(supported, locale) {
            selectedLocale = supported
            let transcriber = DictationTranscriber(
                locale: supported,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            module = transcriber
            startResults = { self.consume(transcriber.results, session: session) { $0.text } }
        } else {
            throw ComposerSpeechFailure.unsupportedLanguage
        }
        try requireCurrent(session)
        let modules = [module]
        let status = await AssetInventory.status(forModules: modules)
        try requireCurrent(session)
        guard status != .unsupported else { throw ComposerSpeechFailure.unavailable }
        do {
            // Reserve returns false when this process already owns the reservation.
            // Release only reservations acquired by this service.
            if try await AssetInventory.reserve(locale: selectedLocale) {
                session.reservedLocale = selectedLocale
            }
            try requireCurrent(session)
            if status != .installed {
                session.callback?(.downloadingModel)
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    session.installation = installation
                    try requireCurrent(session)
                    try await installation.downloadAndInstall()
                    session.installation = nil
                }
                try requireCurrent(session)
                guard await AssetInventory.status(forModules: modules) == .installed else {
                    throw ComposerSpeechFailure.modelDownload
                }
            }
        } catch {
            try requireCurrent(session)
            throw ComposerSpeechFailure.modelDownload
        }
        try requireCurrent(session)

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try audioSession.setActive(true)
            session.audioSessionActive = true
        } catch {
            throw ComposerSpeechFailure.audioUnavailable
        }
        observeAudioChanges(session)
        let engine = AVAudioEngine()
        session.engine = engine
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules, considering: naturalFormat
              ) else { throw ComposerSpeechFailure.audioUnavailable }
        try requireCurrent(session)
        let analyzer = SpeechAnalyzer(modules: modules)
        session.analyzer = analyzer
        // Start consumption only after an analyzer exists to terminate the stream
        // during cleanup, including failures in prepareToAnalyze or engine.start.
        session.resultsTask = startResults()
        let input = try ComposerSpeechAudioInput(source: naturalFormat, destination: format) { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                self.fail(session, with: .audioUnavailable)
            }
        }
        session.input = input
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try requireCurrent(session)
            try await analyzer.start(inputSequence: input.stream)
            try requireCurrent(session)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { buffer, _ in
                input.append(buffer)
            }
            session.tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            try requireCurrent(session)
            throw ComposerSpeechFailure.audioUnavailable
        }
        session.callback?(.recording)
    }

    private static func sameLanguage(_ lhs: Locale, _ rhs: Locale) -> Bool {
        lhs.language.languageCode == rhs.language.languageCode
            && lhs.language.languageCode != nil
    }

    private func consume<S: AsyncSequence & Sendable>(
        _ sequence: S,
        session: Session,
        text: @escaping @Sendable (S.Element) -> AttributedString
    ) -> Task<Void, Error> where S.Element: SpeechModuleResult & Sendable {
        Task { @MainActor [weak self, weak session] in
            do {
                for try await result in sequence {
                    try Task.checkCancellation()
                    guard let self, let session, self.current === session else { return }
                    let transcript = String(text(result).characters)
                    let start = result.range.start.seconds
                    let end = CMTimeRangeGetEnd(result.range).seconds
                    guard start.isFinite, end.isFinite, end >= start else { continue }
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        session.hasTranscript = true
                    }
                    session.callback?(.transcript(text: transcript, start: start, end: end, isFinal: result.isFinal))
                }
                if let self, let session, self.current === session, session.finishTask == nil {
                    self.fail(session, with: .recognitionFailed)
                    throw ComposerSpeechFailure.recognitionFailed
                }
            } catch {
                if error is CancellationError { throw error }
                if let self, let session { self.fail(session, with: .recognitionFailed) }
                throw ComposerSpeechFailure.recognitionFailed
            }
        }
    }

    private func observeAudioChanges(_ session: Session) {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak session] notification in
                // Transfer only immutable values across the actor boundary.
                let isInterruptionEnd = notification.name == AVAudioSession.interruptionNotification
                    && (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        == AVAudioSession.InterruptionType.ended.rawValue
                let routeReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let harmlessRouteChange = notification.name == AVAudioSession.routeChangeNotification
                    && (routeReason == .categoryChange || routeReason == .override)
                guard !isInterruptionEnd, !harmlessRouteChange else { return }
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session else { return }
                    self.fail(session, with: .interrupted)
                }
            }
            session.observers.append(observer)
        }
    }

    private func fail(_ session: Session, with error: ComposerSpeechFailure) {
        guard current === session else { return }
        let callback = session.callback
        cancel()
        callback?(.failed(error))
    }

    private func stopCapture(_ session: Session) {
        session.observers.forEach(NotificationCenter.default.removeObserver)
        session.observers.removeAll()
        session.engine?.stop()
        if session.tapInstalled {
            session.engine?.inputNode.removeTap(onBus: 0)
            session.tapInstalled = false
        }
        if session.audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            session.audioSessionActive = false
        }
    }

    @discardableResult
    private func cleanUp(_ session: Session) -> Task<Void, Never> {
        if let existing = session.cleanupTask { return existing }
        stopCapture(session)
        session.callback = nil
        session.input?.cancel()
        session.setupTask?.cancel()
        session.resultsTask?.cancel()
        session.installation?.progress.cancel()
        let cleanup = Task { @MainActor in
            // A cancelled installation/reservation may still return. Let setup record ownership first.
            _ = await session.setupTask?.result
            await session.analyzer?.cancelAndFinishNow()
            _ = await session.resultsTask?.result
            if let locale = session.reservedLocale {
                await AssetInventory.release(reservedLocale: locale)
                session.reservedLocale = nil
            }
            session.input = nil
            session.analyzer = nil
            session.engine = nil
            session.installation = nil
        }
        session.cleanupTask = cleanup
        Self.cleanupTail = cleanup
        return cleanup
    }
}

/// The tap copies AVAudioEngine's reused buffer before returning. Conversion and
/// timestamps are serialized off the main actor; no audio data is written to disk.
nonisolated private final class ComposerSpeechAudioInput: @unchecked Sendable {
    /// Ownership transfers to the audio queue; the copy is never mutated elsewhere.
    private struct OwnedBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
    }

    /// AVAudioConverter invokes its input block synchronously. The lock also makes
    /// the single-use source explicit to Swift's Sendable input-block contract.
    private final class ConverterSource: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer?
        let ending: Bool
        let lock = NSLock()
        var supplied = false

        init(buffer: AVAudioPCMBuffer?, ending: Bool) {
            self.buffer = buffer
            self.ending = ending
        }

        func supply(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.withLock {
                if let buffer, !supplied {
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                status.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
        }
    }

    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "com.agents-anywhere.composer-speech-audio")
    private let lock = NSLock()
    private let destination: AVAudioFormat
    private let converter: AVAudioConverter?
    private let failure: @Sendable () -> Void
    private var accepting = true
    private var cancelled = false
    private var pending = 0
    // The following fields are used only on queue.
    private var outputFrames: Int64 = 0
    private var failed = false

    init(source: AVAudioFormat, destination: AVAudioFormat, failure: @escaping @Sendable () -> Void) throws {
        self.destination = destination
        self.failure = failure
        if source == destination {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: destination) else {
                throw ComposerSpeechFailure.audioUnavailable
            }
            self.converter = converter
        }
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // AVAudioPCMBuffer is mutable and is recycled as soon as the tap returns.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            failure()
            return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData,
                  source[index].mDataByteSize <= target[index].mDataByteSize else {
                failure()
                return
            }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        lock.lock()
        guard accepting, pending < 64 else {
            let overflow = accepting
            lock.unlock()
            if overflow { failure() }
            return
        }
        pending += 1
        let owned = OwnedBuffer(value: copy)
        queue.async {
            defer { self.lock.withLock { self.pending -= 1 } }
            guard !self.lock.withLock({ self.cancelled }) else { return }
            self.convert(owned.value, ending: false)
        }
        lock.unlock()
    }

    func finish() async {
        await withCheckedContinuation { done in
            lock.withLock {
                accepting = false
                queue.async {
                    if !self.lock.withLock({ self.cancelled }) {
                        self.convert(nil, ending: true)
                    }
                    self.continuation.finish()
                    done.resume()
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            accepting = false
            cancelled = true
        }
        continuation.finish()
    }

    private func convert(_ buffer: AVAudioPCMBuffer?, ending: Bool) {
        guard !failed else { return }
        guard let converter else {
            if let buffer { yield(buffer) }
            return
        }
        let capacity = buffer.map {
            AVAudioFrameCount(ceil(Double($0.frameLength) * destination.sampleRate / $0.format.sampleRate)) + 64
        } ?? 1024
        let source = ConverterSource(buffer: buffer, ending: ending)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else {
                reportFailure()
                return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                source.supply(inputStatus)
            }
            guard error == nil, status != .error else {
                reportFailure()
                return
            }
            if output.frameLength > 0 { yield(output) }
            guard status == .haveData else { return }
        }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        let start = CMTime(value: outputFrames, timescale: CMTimeScale(destination.sampleRate.rounded()))
        outputFrames += Int64(buffer.frameLength)
        if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start)) {
            reportFailure()
        }
    }

    private func reportFailure() {
        guard !failed else { return }
        failed = true
        continuation.finish()
        failure()
    }
}
#endif
