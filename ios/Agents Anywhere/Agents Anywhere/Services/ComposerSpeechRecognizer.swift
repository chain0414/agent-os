#if os(iOS)
import AVFoundation
import Foundation
import UIKit

/// Audio stays in memory and goes directly to Aliyun using a temporary token.
@MainActor
final class ComposerSpeechRecognizer: ComposerSpeechRecognizing {
    private final class Signal {
        private var result: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?
        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func resolve(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private final class Session {
        var callback: (@MainActor (ComposerSpeechEvent) -> Void)?
        var setupTask: Task<Void, Error>?
        var receiveTask: Task<Void, Never>?
        var sendTask: Task<Void, Error>?
        var finishTask: Task<Void, Error>?
        var preparationTimeout: Task<Void, Never>?
        var recordingTimeout: Task<Void, Never>?
        var finishTimeout: Task<Void, Never>?
        var engine: AVAudioEngine?
        var input: ComposerSpeechAudioInput?
        var network: URLSession?
        var socket: URLSessionWebSocketTask?
        var wire = AliyunSpeechProtocol(taskID: UUID().uuidString.lowercased())
        let ready = Signal()
        let finished = Signal()
        var observers: [NSObjectProtocol] = []
        var tapInstalled = false
        var audioSessionActive = false
        var hasTranscript = false
        var finishRequested = false
        var failure: ComposerSpeechFailure?
        var snapshotSequence: Double = 0
        var captureStarted = ContinuousClock.now
        init(callback: @escaping @MainActor (ComposerSpeechEvent) -> Void) { self.callback = callback }
    }

    // AVAudioSession belongs to the process even when several composers exist.
    private static weak var owner: ComposerSpeechRecognizer?
    private var current: Session?
    private let credentials: @MainActor @Sendable () async throws -> V2SpeechCredentials

    init(credentials: @escaping @MainActor @Sendable () async throws -> V2SpeechCredentials = { throw ComposerSpeechFailure.unavailable }) {
        self.credentials = credentials
    }

    isolated deinit { cancel() }

    func start(locale: Locale, onEvent: @escaping @MainActor (ComposerSpeechEvent) -> Void) async throws {
        try Task.checkCancellation()
        cancel()
        if let previous = Self.owner, let active = previous.current { previous.fail(active, with: .interrupted) }
        let session = Session(callback: onEvent)
        current = session
        Self.owner = self
        // Language hints come from the service configuration, never the keyboard.
        let setup = Task { try await self.prepare(session) }
        session.setupTask = setup
        do {
            try await withTaskCancellationHandler {
                try await setup.value
                try self.requireCurrent(session)
            } onCancel: {
                setup.cancel()
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.current === session else { return }
                    self.cancel()
                }
            }
        } catch {
            if let failure = session.failure { throw failure }
            if error is CancellationError { throw error }
            let failure = Self.failure(error)
            fail(session, with: failure)
            throw failure
        }
    }

    func finish() async throws {
        guard let session = current else { return }
        // Stop synchronously, including when credentials are still pending.
        stopCapture(session)
        if let finishing = session.finishTask { return try await finishing.value }
        session.finishTimeout = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() } catch { return }
            guard let self, let session else { return }
            self.fail(session, with: .networkUnavailable)
        }
        let finishing = Task { @MainActor in
            do {
                await session.input?.finish()
                try await session.setupTask?.value
                try self.requireCurrent(session)
                try await session.sendTask?.value
                try self.requireCurrent(session)
                guard let socket = session.socket else { throw ComposerSpeechFailure.networkUnavailable }
                session.finishRequested = true
                try await socket.send(.string(String(decoding: session.wire.finishTask(), as: UTF8.self)))
                try await session.finished.wait()
                try self.requireCurrent(session)
                let hasTranscript = session.hasTranscript
                self.release(session)
                if !hasTranscript { throw ComposerSpeechFailure.noSpeech }
            } catch {
                let failure = session.failure ?? Self.failure(error)
                self.fail(session, with: failure)
                if error is CancellationError, session.failure == nil { throw error }
                throw failure
            }
        }
        session.finishTask = finishing
        try await withTaskCancellationHandler {
            try await finishing.value
        } onCancel: {
            finishing.cancel()
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.current === session else { return }
                self.cancel()
            }
        }
    }

    func cancel() {
        guard let session = current else { return }
        release(session)
    }

    private func requireCurrent(_ session: Session) throws {
        try Task.checkCancellation()
        guard current === session, Self.owner === self else { throw CancellationError() }
    }

    private func prepare(_ session: Session) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        try requireCurrent(session)
        guard granted else { throw ComposerSpeechFailure.microphoneDenied }
        try beginCapture(session)
        session.callback?(.recording)
        try requireCurrent(session)
        session.preparationTimeout = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(20)); try Task.checkCancellation() } catch { return }
            guard let self, let session else { return }
            self.fail(session, with: .networkUnavailable)
        }
        let credential = try await credentials()
        try requireCurrent(session)
        do {
            try AliyunSpeechProtocol.validateCredentials(
                provider: credential.provider, model: credential.model, url: credential.websocketUrl,
                token: credential.token, expiresAt: credential.expiresAt, languageHints: credential.languageHints,
                sampleRate: credential.sampleRate, maxRecordingSeconds: credential.maxRecordingSeconds
            )
        } catch { throw ComposerSpeechFailure.serviceUnavailable }
        if session.finishTask == nil { armRecordingLimit(session, seconds: credential.maxRecordingSeconds) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 330
        let network = URLSession(configuration: configuration, delegate: ComposerSpeechNetworkDelegate(), delegateQueue: nil)
        session.network = network
        var request = URLRequest(url: credential.websocketUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let socket = network.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        session.socket = socket
        session.receiveTask = receive(session, socket: socket)
        socket.resume()
        try await socket.send(.string(String(decoding: session.wire.runTask(model: credential.model, languageHints: credential.languageHints), as: UTF8.self)))
        try await session.ready.wait()
        try requireCurrent(session)
        session.preparationTimeout?.cancel()
        session.preparationTimeout = nil
        guard let input = session.input else { throw ComposerSpeechFailure.audioUnavailable }
        session.sendTask = Task { @MainActor [weak self, weak session] in
            do {
                for await data in input.stream {
                    guard let self, let session else { throw CancellationError() }
                    try self.requireCurrent(session)
                    try await socket.send(.data(data))
                    input.consumed(bytes: data.count)
                }
            } catch {
                if !(error is CancellationError), let self, let session {
                    self.fail(session, with: Self.failure(error, socket: socket))
                }
                throw error
            }
        }
    }

    private func beginCapture(_ session: Session) throws {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try audioSession.setActive(true)
            session.audioSessionActive = true
            let engine = AVAudioEngine()
            session.engine = engine
            let source = engine.inputNode.outputFormat(forBus: 0)
            guard source.channelCount > 0, source.sampleRate > 0,
                  let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
                throw ComposerSpeechFailure.audioUnavailable
            }
            let input = try ComposerSpeechAudioInput(source: source, destination: destination) { [weak self, weak session] in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session else { return }
                    self.fail(session, with: .audioUnavailable)
                }
            }
            session.input = input
            observeAudioChanges(session)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: source) { buffer, _ in input.append(buffer) }
            session.tapInstalled = true
            engine.prepare()
            try engine.start()
            session.captureStarted = .now
            armRecordingLimit(session, seconds: 300)
        } catch { throw ComposerSpeechFailure.audioUnavailable }
    }

    private func armRecordingLimit(_ session: Session, seconds: Int) {
        session.recordingTimeout?.cancel()
        let deadline = session.captureStarted.advanced(by: .seconds(seconds))
        session.recordingTimeout = Task { @MainActor [weak self, weak session] in
            do { try await ContinuousClock().sleep(until: deadline); try Task.checkCancellation() } catch { return }
            guard let self, let session else { return }
            self.fail(session, with: .interrupted)
        }
    }

    private func receive(_ session: Session, socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak session] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, let session else { return }
                    try self.requireCurrent(session)
                    let data: Data
                    switch message {
                    case let .string(text): data = Data(text.utf8)
                    case let .data(bytes): data = bytes
                    @unknown default: throw ComposerSpeechFailure.recognitionFailed
                    }
                    guard let event = try session.wire.receive(data) else { continue }
                    switch event {
                    case .started: session.ready.resolve(.success(()))
                    case let .transcript(text): self.emitSnapshot(text, final: false, session: session)
                    case let .finished(text):
                        guard session.finishRequested else { throw ComposerSpeechFailure.recognitionFailed }
                        self.emitSnapshot(text, final: true, session: session)
                        session.finished.resolve(.success(()))
                        return
                    case let .failed(failure):
                        let mapped: ComposerSpeechFailure
                        switch failure {
                        case .authentication: mapped = .authenticationFailed
                        case .rateLimited: mapped = .rateLimited
                        case .serviceUnavailable: mapped = .serviceUnavailable
                        case .recognition: mapped = .recognitionFailed
                        }
                        throw mapped
                    }
                }
            } catch {
                guard !(error is CancellationError), let self, let session else { return }
                self.fail(session, with: Self.failure(error, socket: socket))
            }
        }
    }

    private func emitSnapshot(_ text: String, final: Bool, session: Session) {
        session.hasTranscript = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard session.hasTranscript else {
            session.callback?(.clearTranscript)
            return
        }
        // One overlapping range replaces the entire draft snapshot. Only the
        // task-finished acknowledgement seals it against later interim updates.
        session.snapshotSequence += 1
        session.callback?(.transcript(text: text, start: 0, end: session.snapshotSequence, isFinal: final))
    }

    private func observeAudioChanges(_ session: Session) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak session] notification in
                let interruptionEnded = notification.name == AVAudioSession.interruptionNotification
                    && (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                let route = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let harmlessRoute = notification.name == AVAudioSession.routeChangeNotification && (route == .categoryChange || route == .override)
                guard !interruptionEnded, !harmlessRoute else { return }
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    self.fail(session, with: .interrupted)
                }
            }
            session.observers.append(observer)
        }
    }

    private func stopCapture(_ session: Session) {
        session.observers.forEach(NotificationCenter.default.removeObserver)
        session.observers.removeAll()
        session.recordingTimeout?.cancel()
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

    private func fail(_ session: Session, with error: ComposerSpeechFailure) {
        guard current === session else { return }
        session.failure = error
        let callback = session.callback
        release(session)
        callback?(.failed(error))
    }

    private func release(_ session: Session) {
        guard current === session else { return }
        current = nil
        if Self.owner === self { Self.owner = nil }
        session.callback = nil
        stopCapture(session)
        session.input?.cancel()
        let error: Error = (session.failure as Error?) ?? CancellationError()
        session.ready.resolve(.failure(error))
        session.finished.resolve(.failure(error))
        session.setupTask?.cancel()
        session.receiveTask?.cancel()
        session.sendTask?.cancel()
        session.preparationTimeout?.cancel()
        session.finishTimeout?.cancel()
        session.socket?.cancel(with: .goingAway, reason: nil)
        session.network?.invalidateAndCancel()
        session.socket = nil
        session.network = nil
        session.engine = nil
        session.input = nil
    }

    private static func failure(_ error: Error, socket: URLSessionWebSocketTask? = nil) -> ComposerSpeechFailure {
        if let error = error as? ComposerSpeechFailure { return error }
        if let response = socket?.response as? HTTPURLResponse {
            if response.statusCode == 401 || response.statusCode == 403 { return .authenticationFailed }
            if response.statusCode == 429 { return .rateLimited }
            if response.statusCode >= 500 { return .serviceUnavailable }
        }
        if error is URLError { return .networkUnavailable }
        return .recognitionFailed
    }
}

/// Reject all redirects so Authorization can never reach a different endpoint.
nonisolated private final class ComposerSpeechNetworkDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
/// The tap copies AVAudioEngine's reused buffer before returning. Conversion is
/// serialized off the main actor; no audio data is written to disk.
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

    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "com.agents-anywhere.composer-speech-audio")
    private let lock = NSLock()
    private let destination: AVAudioFormat
    private let converter: AVAudioConverter?
    private let failure: @Sendable () -> Void
    private var accepting = true
    private var cancelled = false
    private var pending = 0
    // Protected by lock, including acknowledgements from the network consumer.
    private var queuedBytes = 0
    // Accessed only on queue.
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
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(8192))
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

    func consumed(bytes: Int) {
        lock.withLock { queuedBytes = max(0, queuedBytes - bytes) }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.int16ChannelData?[0] else { reportFailure(); return }
        let frames = Int(buffer.frameLength)
        var data = Data(count: frames * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { bytes in
            for frame in 0..<frames {
                bytes.storeBytes(of: samples[frame].littleEndian, toByteOffset: frame * 2, as: Int16.self)
            }
        }
        // Forty seconds at 16 kHz mono PCM16 bounds both startup buffering and
        // network backpressure. Overflow fails visibly instead of dropping speech.
        let accepted = lock.withLock {
            guard !cancelled, queuedBytes + data.count <= 1_280_000 else { return false }
            queuedBytes += data.count
            return true
        }
        guard accepted else { reportFailure(); return }
        if case .dropped = continuation.yield(data) { reportFailure() }
    }

    private func reportFailure() {
        guard !failed else { return }
        failed = true
        continuation.finish()
        failure()
    }
}
#endif
