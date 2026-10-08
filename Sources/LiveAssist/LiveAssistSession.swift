import Combine
import Foundation

/// Owns one explicitly armed Live Assist session. It joins passive system-audio
/// capture, streaming transcription, and the local cue engine without making
/// the view coordinate asynchronous work itself.
///
/// The rail shown to the candidate is frozen for a detected question. Incoming
/// transcript revisions never reorder that rail; a later, distinct question is
/// the only event that can replace it.
@MainActor
public final class LiveAssistSession: ObservableObject {
    @Published public private(set) var heardQuestion = ""
    @Published public private(set) var cuePlan: LiveCuePlan?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var isStarting = false

    public let capture: SystemAudioCaptureService
    public let transcription: SystemAudioTranscriptionService

    private let cueEngine = LiveCueEngine()
    private var questions: [Question] = []
    private var plannedQuestionKey = ""
    /// Speech commonly revises its partial text while an interviewer is still
    /// speaking. Once a real prepared rail has appeared, it must never jump
    /// to a different story because that revision swaps a word or two. This
    /// lock lasts for the current recognition turn only; `Next` and a fresh
    /// recognition request release it.
    private var hasLockedCurrentQuestion = false
    private var restartTask: Task<Void, Never>?
    /// Invalidates an in-flight start when the candidate presses Stop while a
    /// permission or source-refresh await is still pending.
    private var startAttempt = 0

    public init(
        capture: SystemAudioCaptureService = SystemAudioCaptureService(),
        transcription: SystemAudioTranscriptionService = SystemAudioTranscriptionService()
    ) {
        self.capture = capture
        self.transcription = transcription

        capture.onAudioSampleBuffer = transcription.appendFromCapture
        transcription.onTranscriptUpdate = { [weak self] transcript in
            self?.receive(transcript)
        }
    }

    deinit {
        restartTask?.cancel()
    }

    public var isListening: Bool {
        if case .capturing = capture.state { return true }
        return false
    }

    public var hasPreparedRail: Bool {
        cuePlan?.resolution == .matched
    }

    /// Updates the live set whenever setup changes. The existing displayed rail
    /// is deliberately retained so a SwiftData refresh cannot move the
    /// candidate backwards mid-answer.
    public func setQuestions(_ questions: [Question]) {
        self.questions = questions
    }

    /// Refreshes the user-visible app list. This is read-only and does not
    /// initiate capture; macOS asks for permission only from a user action.
    public func refreshAudioSources() async {
        await capture.refreshAvailableApplications()
    }

    @discardableResult
    public func requestCapturePermission() -> Bool {
        let granted = capture.requestScreenRecordingPermission()
        if !granted {
            lastErrorMessage = "Allow Screen & System Audio Recording, then refresh the source list."
        }
        return granted
    }

    public func selectAudioSource(id: CapturableApplication.ID?) {
        guard capture.selectApplication(id: id) else {
            lastErrorMessage = "That meeting app is no longer available. Refresh the list and choose it again."
            return
        }
        lastErrorMessage = nil
    }

    /// Starts an explicitly armed session. The call merely observes a copy of
    /// the selected app's digital output; it never changes the user's selected
    /// speakers/headphones, enables the microphone, or plays the captured data.
    public func startListening() async {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        startAttempt &+= 1
        let attempt = startAttempt
        lastErrorMessage = nil
        restartTask?.cancel()

        if capture.permission != .granted {
            guard requestCapturePermission() else { return }
        }
        await capture.refreshAvailableApplications()
        guard attempt == startAttempt else { return }
        guard capture.selectedApplication != nil else {
            lastErrorMessage = "Choose the meeting app whose audio you want to hear first."
            return
        }

        do {
            try await transcription.start()
            guard attempt == startAttempt else {
                transcription.stop()
                return
            }
            await capture.startCapture()
            guard attempt == startAttempt else {
                await capture.stopCapture()
                transcription.stop()
                return
            }
            guard isListening else {
                transcription.stop()
                lastErrorMessage = Self.captureErrorMessage(from: capture.state)
                return
            }
        } catch {
            transcription.stop()
            lastErrorMessage = error.localizedDescription
        }
    }

    public func stopListening() async {
        startAttempt &+= 1
        restartTask?.cancel()
        restartTask = nil
        await capture.stopCapture()
        transcription.stop()
    }

    /// Clears the current rail only when the candidate explicitly asks for a
    /// fresh question. It does not modify their saved interview material.
    public func prepareForNextQuestion() {
        heardQuestion = ""
        cuePlan = nil
        plannedQuestionKey = ""
        hasLockedCurrentQuestion = false
        lastErrorMessage = nil

        guard isListening else { return }
        restartRecognition(clearTranscript: true)
    }

    /// Manual selection uses exactly the same ordered rail as automatic
    /// matching, so the escape hatch does not revert to a fixed script.
    public func showPreparedQuestion(_ question: Question) {
        let analysis = cueEngine.analyze(question.prompt)
        let match = LiveRankedQuestion(
            question: question,
            score: Int.max,
            evidence: [],
            position: 0
        )
        heardQuestion = question.prompt
        cuePlan = LiveCuePlan(
            analysis: analysis,
            resolution: .matched,
            match: match,
            steps: cueEngine.cueRail(for: question, analysis: analysis)
        )
        plannedQuestionKey = Self.questionKey(question.prompt)
        hasLockedCurrentQuestion = true
        lastErrorMessage = nil
    }

    /// Receives one deduplicated Speech update. Kept internal so the
    /// interview-critical turn sequencing can be exercised without audio
    /// devices, Screen Recording, or Speech Recognition permissions.
    func receive(_ transcript: SystemAudioTranscriptionService.Transcript) {
        guard !transcript.text.isEmpty else {
            restartAfterFinalTranscriptIfNeeded(transcript)
            return
        }
        guard let question = LiveTranscriptQuestionExtractor.latestQuestion(in: transcript.text) else {
            restartAfterFinalTranscriptIfNeeded(transcript)
            return
        }

        // Keep the first confident rail exactly where it was while Speech
        // revises a partial result. A final callback still needs to re-arm
        // recognition for the next interviewer turn, but must not replace the
        // rail the candidate is already using.
        if hasLockedCurrentQuestion {
            if transcript.isFinal, isListening {
                restartRecognition(clearTranscript: true)
            }
            return
        }

        let key = Self.questionKey(question)
        guard !key.isEmpty else {
            restartAfterFinalTranscriptIfNeeded(transcript)
            return
        }

        // A partial result may revise wording many times. Do not give the
        // candidate a rail until ASR has either identified a question mark,
        // reached a final result, or crossed a conservative question-shape
        // threshold. Once planned, that rail is immutable for this key.
        guard transcript.isFinal
                || question.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                || LiveTranscriptQuestionExtractor.isLikelyQuestion(question) else {
            restartAfterFinalTranscriptIfNeeded(transcript)
            return
        }

        guard key != plannedQuestionKey else {
            // A final callback often has exactly the same words as the
            // partial that put the rail on screen. It still closes the Speech
            // request and must start a fresh one for the follow-up question.
            restartAfterFinalTranscriptIfNeeded(transcript)
            return
        }
        let plan = cueEngine.plan(transcript: question, among: questions)
        heardQuestion = question
        cuePlan = plan
        plannedQuestionKey = key
        hasLockedCurrentQuestion = plan.resolution == .matched || transcript.isFinal

        // Finalized speech recognition requests cannot receive further audio.
        // Re-arm a clean request in the background while retaining the current
        // rail, ready for the interviewer's eventual follow-up.
        restartAfterFinalTranscriptIfNeeded(transcript)
    }

    private func restartAfterFinalTranscriptIfNeeded(
        _ transcript: SystemAudioTranscriptionService.Transcript
    ) {
        guard transcript.isFinal, isListening else { return }
        restartRecognition(clearTranscript: true)
    }

    private func restartRecognition(clearTranscript: Bool) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            // Leave a small boundary after a finalized result. This prevents a
            // terminal callback from racing a replacement request, while it is
            // imperceptible to the next interviewer turn.
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.transcription.reset(clearTranscript: clearTranscript)
            self.hasLockedCurrentQuestion = false
            self.plannedQuestionKey = ""
            do {
                try self.transcription.startAuthorizedRecognition()
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private static func captureErrorMessage(from state: SystemAudioCaptureState) -> String {
        if case let .failed(message) = state { return message }
        if case .permissionRequired = state {
            return "Screen & System Audio Recording permission is required to listen to a meeting app."
        }
        return "Live audio capture did not start. Refresh the source and try again."
    }

    private static func questionKey(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Extracts one likely interviewer turn from the evolving transcript supplied
/// by Speech. It is intentionally deterministic and cautious: a weak partial
/// never replaces an already selected response rail.
enum LiveTranscriptQuestionExtractor {
    static func latestQuestion(in transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let lastQuestionMark = trimmed.lastIndex(of: "?") {
            // Find a preceding sentence boundary, not the question mark we
            // just found. Including that terminal mark in the search would
            // advance to the end and turn every completed question into an
            // empty string.
            let beforeQuestion = trimmed[..<lastQuestionMark]
            let start = beforeQuestion.lastIndex(where: { ".!?".contains($0) })
                .map { trimmed.index(after: $0) } ?? trimmed.startIndex
            return String(trimmed[start...lastQuestionMark])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let start = trimmed.lastIndex(where: { ".!".contains($0) })
            .map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let candidate = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return isLikelyQuestion(candidate) ? candidate : nil
    }

    static func isLikelyQuestion(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.split(whereSeparator: \.isWhitespace).count >= 4 else { return false }
        return [
            "tell me", "describe", "walk me", "give me", "what ",
            "why ", "how ", "when ", "where ", "which ", "could you",
            "can you", "have you", "do you", "did you", "would you"
        ].contains { normalized.hasPrefix($0) }
    }
}
