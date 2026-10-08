@preconcurrency import AVFAudio
import Combine
@preconcurrency import CoreMedia
import Foundation
@preconcurrency import Speech

/// Turns PCM audio sample buffers from a system-audio capture into a live
/// speech transcript. The capture itself remains outside this type: callers
/// retain control of ScreenCaptureKit, routing, and whether audio is audible
/// to the user.
///
/// All public state and lifecycle methods are main-actor isolated, making the
/// service safe to bind directly to SwiftUI. Forward a capture callback with
/// `service.appendFromCapture(sampleBuffer)`.
@MainActor
public final class SystemAudioTranscriptionService: NSObject, ObservableObject {
    public enum Authorization: String, Equatable, Sendable {
        case notDetermined
        case requesting
        case authorized
        case denied
        case restricted
    }

    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case ready
        case listening
        case finishing
        case unavailable
        case failed(String)
    }

    public enum ServiceError: LocalizedError, Equatable, Sendable {
        case authorizationDenied
        case speechRecognitionUnavailable
        case unsupportedAudioFormat

        public var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Speech recognition permission has not been granted."
            case .speechRecognitionUnavailable:
                return "Speech recognition is not currently available for this language."
            case .unsupportedAudioFormat:
                return "The captured audio is not PCM audio that Speech can transcribe."
            }
        }
    }

    /// A single UI-friendly snapshot. `isFinal` is true only after Speech has
    /// committed a recognition segment, not merely because input has ended.
    public struct Transcript: Equatable, Sendable {
        public let text: String
        public let isFinal: Bool

        public init(text: String = "", isFinal: Bool = false) {
            self.text = text
            self.isFinal = isFinal
        }
    }

    @Published public private(set) var authorization: Authorization
    @Published public private(set) var state: State
    @Published public private(set) var transcript: Transcript

    /// Called on the main actor after `transcript` changes. It is optional so
    /// SwiftUI consumers can simply observe the published property instead.
    public var onTranscriptUpdate: ((Transcript) -> Void)?

    public let locale: Locale
    public let prefersOnDeviceRecognition: Bool

    private let recognizer: SFSpeechRecognizer?
    /// The input gate is deliberately independent from the main actor: the
    /// ScreenCaptureKit callback can copy/append PCM on its own serial sample
    /// queue without scheduling dozens of UI tasks per second.
    private nonisolated let audioInput = SpeechAudioInput()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = 0
    private var deliveryGate = TranscriptDeliveryGate()

    public init(
        locale: Locale = .current,
        prefersOnDeviceRecognition: Bool = true
    ) {
        let initialAuthorization = Self.currentAuthorization()
        let initialRecognizer = SFSpeechRecognizer(locale: locale)
        self.locale = locale
        self.prefersOnDeviceRecognition = prefersOnDeviceRecognition
        self.recognizer = initialRecognizer
        self.authorization = initialAuthorization
        self.transcript = Transcript()

        switch initialAuthorization {
        case .authorized:
            self.state = initialRecognizer == nil ? .unavailable : .ready
        case .denied, .restricted:
            self.state = .idle
        case .notDetermined, .requesting:
            self.state = .idle
        }

        super.init()
    }

    /// Requests the system Speech permission when needed. This is intentionally
    /// separate from capture permission: system-audio capture and transcription
    /// have independent macOS privacy controls.
    @discardableResult
    public func requestAuthorization() async -> Authorization {
        let current = Self.currentAuthorization()
        guard current == .notDetermined else {
            authorization = current
            refreshReadyStateIfNeeded()
            return current
        }

        authorization = .requesting
        state = .requestingPermission

        let resolved: Authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.authorization(for: status))
            }
        }

        authorization = resolved
        switch resolved {
        case .authorized:
            state = recognizer == nil ? .unavailable : .ready
        case .denied, .restricted:
            state = .idle
        case .notDetermined, .requesting:
            state = .idle
        }
        return resolved
    }

    /// Begins a fresh streaming recognition request. It never starts audio
    /// capture and therefore does not change Zoom, headphones, or any output
    /// route; append captured system-audio sample buffers separately.
    public func start() async throws {
        let permission = await requestAuthorization()
        guard permission == .authorized else {
            throw ServiceError.authorizationDenied
        }
        try startAuthorizedRecognition()
    }

    /// Starts a recognition request when the caller already owns the
    /// permission flow. This is useful when a Live session requests all its
    /// permissions up front.
    public func startAuthorizedRecognition() throws {
        guard authorization == .authorized || Self.currentAuthorization() == .authorized else {
            throw ServiceError.authorizationDenied
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            throw ServiceError.speechRecognitionUnavailable
        }

        cancelRecognition(clearTranscript: false)
        generation &+= 1
        let requestGeneration = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if prefersOnDeviceRecognition && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        audioInput.install(request, generation: requestGeneration)
        state = .listening
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Speech invokes this on its own queue. Moving back to MainActor
            // also serializes it with append/stop/reset and protects UI state.
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.handleRecognitionResult(result, error: error)
            }
        }
    }

    /// Appends a PCM buffer supplied by a system-audio capture service. Buffers
    /// received before `start()` or after `finishCurrentUtterance()` are safely
    /// ignored, which makes capture shutdown ordering harmless.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        handle(audioInput.append(sampleBuffer))
    }

    /// Thread-safe entry point for a ScreenCaptureKit sample-handler queue.
    /// Valid buffers are copied and appended on that queue; only a malformed
    /// buffer schedules a main-actor update, so the live UI stays responsive.
    public nonisolated func appendFromCapture(_ sampleBuffer: CMSampleBuffer) {
        let outcome = audioInput.append(sampleBuffer)
        if case let .unsupportedFormat(generation) = outcome {
            Task { @MainActor [weak self] in
                self?.handle(.unsupportedFormat(generation: generation))
            }
        }
    }

    /// Signals end-of-input but leaves the recognition task alive long enough
    /// to deliver its final segment. Call `stop()` when the result is no longer
    /// useful and should be cancelled immediately.
    public func finishCurrentUtterance() {
        guard state == .listening else { return }
        state = .finishing
        audioInput.endAudio()
    }

    /// Cancels the active request and retains the last displayed transcript.
    public func stop() {
        cancelRecognition(clearTranscript: false)
        refreshReadyStateIfNeeded()
    }

    /// Cancels an in-flight task, invalidates any late callback, and optionally
    /// clears the text shown to the user. It is safe to call repeatedly.
    public func reset(clearTranscript: Bool = true) {
        cancelRecognition(clearTranscript: clearTranscript)
        refreshReadyStateIfNeeded()
    }

    /// Delivers a recognition result through the same published callback used
    /// by Speech. This is intentionally internal: it gives the automated
    /// interview simulation a deterministic seam without opening a mic,
    /// requesting Speech permission, or changing an audio route.
    ///
    /// Production capture always reaches this through
    /// `handleRecognitionResult(_:error:)` below.
    func acceptRecognizedTranscriptForTesting(_ transcript: Transcript) {
        publish(transcript)
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            acceptRecognizedTranscriptForTesting(Transcript(
                text: result.bestTranscription.formattedString,
                isFinal: result.isFinal
            ))
            if result.isFinal {
                recognitionTask = nil
                audioInput.clear()
                refreshReadyStateIfNeeded()
            }
        }

        if let error {
            // A final result and its terminal task callback can arrive
            // together. Preserve that usable final answer rather than turning
            // the UI into an error after success.
            guard !transcript.isFinal else { return }
            fail(error)
        }
    }

    private func publish(_ newTranscript: Transcript) {
        guard let update = deliveryGate.accept(newTranscript) else { return }
        transcript = update
        onTranscriptUpdate?(update)
    }

    private func fail(_ error: Error) {
        generation &+= 1
        audioInput.endAudio()
        audioInput.clear()
        recognitionTask?.cancel()
        recognitionTask = nil
        state = .failed(error.localizedDescription)
    }

    private func cancelRecognition(clearTranscript: Bool) {
        generation &+= 1
        audioInput.endAudio()
        audioInput.clear()
        recognitionTask?.cancel()
        recognitionTask = nil
        if clearTranscript {
            publish(Transcript())
        }
    }

    private func refreshReadyStateIfNeeded() {
        authorization = Self.currentAuthorization()
        if authorization == .authorized {
            state = recognizer?.isAvailable == true ? .ready : .unavailable
        } else {
            state = .idle
        }
    }

    private static func currentAuthorization() -> Authorization {
        authorization(for: SFSpeechRecognizer.authorizationStatus())
    }

    private static func authorization(for status: SFSpeechRecognizerAuthorizationStatus) -> Authorization {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private func handle(_ outcome: SpeechAudioInput.AppendOutcome) {
        guard case let .unsupportedFormat(requestGeneration) = outcome,
              requestGeneration == generation
        else {
            return
        }
        fail(ServiceError.unsupportedAudioFormat)
    }
}

/// Filters only identical streaming callbacks. A final update with the same
/// words as a partial remains significant: it is the utterance boundary that
/// lets Live Assist re-arm recognition for the next interviewer turn.
struct TranscriptDeliveryGate {
    private var lastDelivered = SystemAudioTranscriptionService.Transcript()

    mutating func accept(
        _ transcript: SystemAudioTranscriptionService.Transcript
    ) -> SystemAudioTranscriptionService.Transcript? {
        guard transcript != lastDelivered else { return nil }
        lastDelivered = transcript
        return transcript
    }
}

/// Serializes the tiny audio-input critical section independently of the UI.
/// `SFSpeechAudioBufferRecognitionRequest` itself is intentionally never
/// exposed outside this gate, so stopping a live session cannot race an audio
/// callback that is appending its last sample.
private final class SpeechAudioInput: @unchecked Sendable {
    enum AppendOutcome: Sendable {
        case appended
        case ignored
        case unsupportedFormat(generation: Int)
    }

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation: Int?

    func install(_ request: SFSpeechAudioBufferRecognitionRequest, generation: Int) {
        lock.lock()
        self.request = request
        self.generation = generation
        lock.unlock()
    }

    func clear() {
        lock.lock()
        request = nil
        generation = nil
        lock.unlock()
    }

    func endAudio() {
        lock.lock()
        request?.endAudio()
        request = nil
        generation = nil
        lock.unlock()
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> AppendOutcome {
        // Do the copy before acquiring the request lock. It is safe for a
        // stop to win while this happens; the final lock check will then turn
        // this buffer into a harmless ignored sample.
        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else {
            lock.lock()
            let activeGeneration = generation
            lock.unlock()
            return activeGeneration.map(AppendOutcome.unsupportedFormat) ?? .ignored
        }

        lock.lock()
        defer { lock.unlock() }
        guard let request else { return .ignored }
        request.append(pcmBuffer)
        return .appended
    }

    /// Speech accepts `AVAudioPCMBuffer`, while ScreenCaptureKit delivers
    /// `CMSampleBuffer`. CoreMedia performs the channel-aware PCM copy, so this
    /// supports both interleaved and non-interleaved capture formats.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              sampleCount <= Int(Int32.max),
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              )
        else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }
}
