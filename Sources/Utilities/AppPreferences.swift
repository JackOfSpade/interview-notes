import SwiftUI
import Combine

@MainActor
public final class AppPreferences: ObservableObject {
    public static let shared = AppPreferences()

    public enum Keys {
        public static let windowTransparency = "windowTransparency"
        public static let autoScrollAnswers = "autoScrollAnswers"
        public static let teleprompterWPM = "teleprompterWPM"
        public static let teleprompterStartDelay = "teleprompterStartDelay"
        public static let hasCompletedOnboarding = "hasCompletedOnboarding"
        public static let lastSelectedInterviewID = "lastSelectedInterviewID"
        public static let lastSelectedQuestionID = "lastSelectedQuestionID"
        public static let isCameraSnapped = "isCameraSnapped"
        public static let cameraSnapDisplayID = "cameraSnapDisplayID"
        public static let pendingSetupFrameX = "pendingSetupFrameX"
        public static let pendingSetupFrameY = "pendingSetupFrameY"
        public static let pendingSetupFrameWidth = "pendingSetupFrameWidth"
        public static let pendingSetupFrameHeight = "pendingSetupFrameHeight"
    }

    private let defaults: UserDefaults

    // Store normalized values separately so assigning an out-of-range value never
    // re-enters a property's observer while it is being published.
    @Published private var storedWindowTransparency: Double

    public var windowTransparency: Double {
        get { storedWindowTransparency }
        set {
            let clamped = Self.clampedWindowTransparency(newValue)
            storedWindowTransparency = clamped
            defaults.set(clamped, forKey: Keys.windowTransparency)
        }
    }

    @Published public var autoScrollAnswers: Bool {
        didSet {
            defaults.set(autoScrollAnswers, forKey: Keys.autoScrollAnswers)
        }
    }

    @Published private var storedTeleprompterWPM: Int

    public var teleprompterWPM: Int {
        get { storedTeleprompterWPM }
        set {
            let clamped = Self.clampedTeleprompterWPM(newValue)
            storedTeleprompterWPM = clamped
            defaults.set(clamped, forKey: Keys.teleprompterWPM)
        }
    }

    @Published private var storedTeleprompterStartDelay: Int

    public var teleprompterStartDelay: Int {
        get { storedTeleprompterStartDelay }
        set {
            let valid = Self.validTeleprompterStartDelay(newValue)
            storedTeleprompterStartDelay = valid
            defaults.set(valid, forKey: Keys.teleprompterStartDelay)
        }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)
        }
    }

    @Published public var lastSelectedInterviewID: String? {
        didSet {
            defaults.set(lastSelectedInterviewID, forKey: Keys.lastSelectedInterviewID)
        }
    }

    @Published public var lastSelectedQuestionID: String? {
        didSet {
            defaults.set(lastSelectedQuestionID, forKey: Keys.lastSelectedQuestionID)
        }
    }

    @Published public var isCameraSnapped: Bool {
        didSet {
            defaults.set(isCameraSnapped, forKey: Keys.isCameraSnapped)
        }
    }

    @Published public var cameraSnapDisplayID: CGDirectDisplayID? {
        didSet {
            if let id = cameraSnapDisplayID {
                defaults.set(id, forKey: Keys.cameraSnapDisplayID)
            } else {
                defaults.removeObject(forKey: Keys.cameraSnapDisplayID)
            }
        }
    }

    /// Set immediately before entering Live. It survives a quit while the
    /// compact Live frame is autosaved, so the next Setup launch can recover
    /// the user's roomy workspace dimensions.
    public var pendingSetupFrame: CGRect? {
        get {
            let keys = [
                Keys.pendingSetupFrameX,
                Keys.pendingSetupFrameY,
                Keys.pendingSetupFrameWidth,
                Keys.pendingSetupFrameHeight
            ]
            guard keys.allSatisfy({ defaults.object(forKey: $0) != nil }) else {
                return nil
            }

            let frame = CGRect(
                x: defaults.double(forKey: Keys.pendingSetupFrameX),
                y: defaults.double(forKey: Keys.pendingSetupFrameY),
                width: defaults.double(forKey: Keys.pendingSetupFrameWidth),
                height: defaults.double(forKey: Keys.pendingSetupFrameHeight)
            )
            guard frame.width > 0, frame.height > 0 else { return nil }
            return frame
        }
        set {
            guard let frame = newValue else {
                clearPendingSetupFrame()
                return
            }
            defaults.set(frame.origin.x, forKey: Keys.pendingSetupFrameX)
            defaults.set(frame.origin.y, forKey: Keys.pendingSetupFrameY)
            defaults.set(frame.size.width, forKey: Keys.pendingSetupFrameWidth)
            defaults.set(frame.size.height, forKey: Keys.pendingSetupFrameHeight)
        }
    }

    public func clearPendingSetupFrame() {
        defaults.removeObject(forKey: Keys.pendingSetupFrameX)
        defaults.removeObject(forKey: Keys.pendingSetupFrameY)
        defaults.removeObject(forKey: Keys.pendingSetupFrameWidth)
        defaults.removeObject(forKey: Keys.pendingSetupFrameHeight)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let windowTransparency = defaults.object(forKey: Keys.windowTransparency) != nil
            ? Self.clampedWindowTransparency(defaults.double(forKey: Keys.windowTransparency))
            : 0.0
        self.storedWindowTransparency = windowTransparency
        self.autoScrollAnswers = defaults.bool(forKey: Keys.autoScrollAnswers)
        let teleprompterWPM = defaults.object(forKey: Keys.teleprompterWPM) != nil
            ? Self.clampedTeleprompterWPM(defaults.integer(forKey: Keys.teleprompterWPM))
            : 120
        self.storedTeleprompterWPM = teleprompterWPM
        let teleprompterStartDelay = defaults.object(forKey: Keys.teleprompterStartDelay) != nil
            ? Self.validTeleprompterStartDelay(defaults.integer(forKey: Keys.teleprompterStartDelay))
            : 3
        self.storedTeleprompterStartDelay = teleprompterStartDelay
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.lastSelectedInterviewID = defaults.string(forKey: Keys.lastSelectedInterviewID)
        self.lastSelectedQuestionID = defaults.string(forKey: Keys.lastSelectedQuestionID)
        self.isCameraSnapped = defaults.bool(forKey: Keys.isCameraSnapped)
        let displayID = defaults.object(forKey: Keys.cameraSnapDisplayID) as? UInt32
        self.cameraSnapDisplayID = displayID

        // Repair values saved by an older version or written externally.
        defaults.set(windowTransparency, forKey: Keys.windowTransparency)
        defaults.set(teleprompterWPM, forKey: Keys.teleprompterWPM)
        defaults.set(teleprompterStartDelay, forKey: Keys.teleprompterStartDelay)
    }

    private static func clampedWindowTransparency(_ value: Double) -> Double {
        min(max(value, 0.0), 0.4)
    }

    private static func clampedTeleprompterWPM(_ value: Int) -> Int {
        min(max(value, 70), 200)
    }

    private static func validTeleprompterStartDelay(_ value: Int) -> Int {
        [0, 3, 5].contains(value) ? value : 3
    }
}
