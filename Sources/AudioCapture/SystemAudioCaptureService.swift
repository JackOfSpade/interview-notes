@preconcurrency import CoreMedia
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// A running application that can be selected as the source of captured audio.
///
/// The process identifier is deliberate: an app can be quit and relaunched while
/// the picker is open, in which case its old selection must not silently refer
/// to the new process.
public struct CapturableApplication: Identifiable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: pid_t
    public let name: String

    public var id: String {
        "\(bundleIdentifier):\(processIdentifier)"
    }

    public init(bundleIdentifier: String, processIdentifier: pid_t, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
    }
}

/// Screen Recording is the macOS permission used by ScreenCaptureKit to read
/// another app's audio. macOS does not expose a separate, reliable
/// not-determined-versus-denied state, so `.required` intentionally covers
/// both until the user grants it in the system prompt or Settings.
public enum SystemAudioCapturePermission: Equatable, Sendable {
    case unknown
    case required
    case granted
}

public enum SystemAudioCaptureState: Equatable, Sendable {
    case idle
    case permissionRequired
    case ready
    case starting(CapturableApplication)
    case capturing(CapturableApplication)
    case stopping
    case failed(String)
}

/// A passive ScreenCaptureKit audio reader for one selected application.
///
/// It never changes the default audio device, opens an audio input, or plays
/// audio. `SCStream` receives a copy of the selected app's output before it is
/// sent to speakers or headphones, so an ongoing Zoom/Meet call keeps using
/// its existing device. The stream is intentionally configured without a
/// microphone output; only `.audio` sample buffers are delivered.
@MainActor
public final class SystemAudioCaptureService: NSObject, ObservableObject {
    @Published public private(set) var availableApplications: [CapturableApplication] = []
    @Published public private(set) var selectedApplication: CapturableApplication?
    @Published public private(set) var permission: SystemAudioCapturePermission = .unknown
    @Published public private(set) var state: SystemAudioCaptureState = .idle

    /// Runs on the capture queue, not the main actor. Keep work here very
    /// short; copy/enqueue samples for transcription rather than blocking it.
    /// Setting this handler does not start capture.
    public var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)? {
        get { sampleOutput.handler }
        set { sampleOutput.handler = newValue }
    }

    private let sampleOutput = SystemAudioSampleOutput()
    private let streamDelegate: SystemAudioStreamDelegate
    private let sampleQueue = DispatchQueue(
        label: "com.rehearse.system-audio-capture.samples",
        qos: .userInitiated
    )
    private var stream: SCStream?

    public override init() {
        let streamDelegate = SystemAudioStreamDelegate()
        self.streamDelegate = streamDelegate
        super.init()

        streamDelegate.onStop = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedStop(message: message)
            }
        }
    }

    deinit {
        // `SCStream.stopCapture()` is asynchronous. There is no safe way to
        // await it during deinitialization, but releasing the stream ends the
        // capture session. Normal callers should always use `stopCapture()`.
        stream = nil
    }

    /// Refreshes the app picker. This is read-only and does not trigger the
    /// Screen Recording prompt; call `requestScreenRecordingPermission()` from
    /// a user-initiated UI action when this reports `.permissionRequired`.
    public func refreshAvailableApplications() async {
        guard CGPreflightScreenCaptureAccess() else {
            permission = .required
            availableApplications = []
            selectedApplication = nil
            state = .permissionRequired
            return
        }

        permission = .granted

        do {
            let content = try await shareableContent()
            let applications = Self.makeApplications(from: content.applications)
            availableApplications = applications

            if let selectedApplication,
               !applications.contains(selectedApplication) {
                self.selectedApplication = nil
            }

            if stream == nil {
                state = .ready
            }
        } catch {
            setFailure(error)
        }
    }

    /// Presents the standard macOS Screen Recording permission request. It
    /// does not start audio capture and does not touch audio routing.
    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        permission = granted ? .granted : .required
        state = granted ? .idle : .permissionRequired
        return granted
    }

    /// Selects an app from the latest list returned by
    /// `refreshAvailableApplications()`.
    @discardableResult
    public func selectApplication(id: CapturableApplication.ID?) -> Bool {
        guard let id else {
            selectedApplication = nil
            return true
        }
        guard let application = availableApplications.first(where: { $0.id == id }) else {
            return false
        }
        selectedApplication = application
        return true
    }

    /// Begins passive capture of the selected app's output. The application
    /// must still be running; a stale selection fails explicitly rather than
    /// falling back to system-wide audio.
    public func startCapture() async {
        guard let selectedApplication else {
            state = .failed("Choose a meeting app before starting audio capture.")
            return
        }
        await startCapture(application: selectedApplication)
    }

    /// Begins passive capture of a specific current app selection.
    public func startCapture(application: CapturableApplication) async {
        guard stream == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            permission = .required
            state = .permissionRequired
            return
        }

        permission = .granted
        state = .starting(application)

        do {
            let content = try await shareableContent()
            guard let sourceApplication = content.applications.first(where: {
                $0.bundleIdentifier == application.bundleIdentifier
                    && $0.processID == application.processIdentifier
            }) else {
                state = .failed("\(application.name) is no longer running. Refresh the app list and choose it again.")
                return
            }
            guard let display = content.displays.first else {
                state = .failed("No display is available for ScreenCaptureKit to anchor the audio stream.")
                return
            }

            let filter = SCContentFilter(
                display: display,
                including: [sourceApplication],
                exceptingWindows: []
            )
            let configuration = Self.makeAudioConfiguration()
            let newStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamDelegate
            )
            try newStream.addStreamOutput(
                sampleOutput,
                type: .audio,
                sampleHandlerQueue: sampleQueue
            )
            try await newStream.startCapture()

            stream = newStream
            selectedApplication = application
            state = .capturing(application)
        } catch {
            setFailure(error)
        }
    }

    /// Stops capture while leaving Zoom/Meet and the user's selected headphones
    /// exactly as they were.
    public func stopCapture() async {
        guard let stream else {
            if permission == .granted { state = .ready }
            return
        }

        state = .stopping
        self.stream = nil
        do {
            try await stream.stopCapture()
            state = .ready
        } catch {
            setFailure(error)
        }
    }

    private func handleUnexpectedStop(message: String) {
        guard stream != nil else { return }
        stream = nil
        state = .failed(message)
    }

    private func setFailure(_ error: Error) {
        stream = nil
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .failed(message.isEmpty ? "ScreenCaptureKit could not start audio capture." : message)
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(
                        throwing: SystemAudioCaptureServiceError.noShareableContent
                    )
                }
            }
        }
    }

    private static func makeApplications(
        from applications: [SCRunningApplication]
    ) -> [CapturableApplication] {
        applications
            .map {
                CapturableApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processID,
                    name: $0.applicationName
                )
            }
            // ScreenCaptureKit includes this app in some environments. It
            // cannot be a useful source and excluding it prevents accidental
            // feedback loops if audio playback is added later.
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func makeAudioConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // No microphone output is added. This service deliberately observes
        // only `SCStreamOutputType.audio`, which is app/system output.
        return configuration
    }
}

private enum SystemAudioCaptureServiceError: LocalizedError {
    case noShareableContent

    var errorDescription: String? {
        "macOS did not return any shareable content. Check Screen Recording permission and try again."
    }
}

/// Kept separate from the main-actor service because ScreenCaptureKit calls
/// this object on its sample queue.
private final class SystemAudioSampleOutput: NSObject, SCStreamOutput {
    var handler: ((CMSampleBuffer) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        handler?(sampleBuffer)
    }
}

/// SCStream delegates are also called away from the main actor. Convert the
/// error to a Sendable string before handing it back to the observable service.
private final class SystemAudioStreamDelegate: NSObject, SCStreamDelegate {
    var onStop: ((String) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        onStop?(message.isEmpty ? "macOS stopped the audio capture stream." : message)
    }
}
