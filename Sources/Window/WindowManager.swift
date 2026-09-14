import AppKit
import SwiftUI
import Combine

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    public static let setupMinimumSize = NSSize(width: 620, height: 480)
    public static let liveMinimumSize = NSSize(width: 360, height: 240)
    public static let liveTargetSize = NSSize(width: 520, height: 360)

    @Published public var isSnapped: Bool = false
    @Published public private(set) var isLiveLayout: Bool = false
    @Published public var currentWindow: NSWindow?

    private var activeDisplayID: CGDirectDisplayID?
    private var screenParametersCancellable: AnyCancellable?
    private var setupFrameBeforeLive: NSRect?

    public init() {
        self.isSnapped = AppPreferences.shared.isCameraSnapped
        self.activeDisplayID = AppPreferences.shared.cameraSnapDisplayID

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDisplayChange()
            }
        }
    }

    public func registerWindow(_ window: NSWindow) {
        self.currentWindow = window
        let autosavedFrame = window.frame
        window.minSize = minimumSize
        window.isOpaque = false
        window.backgroundColor = .clear

        // If the process quit while Live was active, AppKit restores its
        // compact autosaved frame before SwiftUI has a chance to show Setup.
        // Restore the saved setup frame first, then let snap place it on the
        // preferred display. Older versions have no pending frame, so expand
        // any compact autosave to the normal setup minimum as a safe fallback.
        let pendingSetupFrame = AppPreferences.shared.pendingSetupFrame
        if Self.shouldRestoreSetupFrame(
            pendingSetupFrame: pendingSetupFrame,
            autosavedFrame: autosavedFrame
        ), let screen = screenContaining(window) {
            let frameToRestore = pendingSetupFrame ?? autosavedFrame
            let restoredFrame = isSnapped
                ? snappedFrame(for: frameToRestore.size, on: screen)
                : constrainedFrame(frameToRestore, on: screen)
            window.setFrame(restoredFrame, display: true, animate: false)

            if pendingSetupFrame != nil {
                AppPreferences.shared.clearPendingSetupFrame()
            }
        }

        // Restore snapped state after recovering the correct setup dimensions.
        if isSnapped {
            reapplySnap(animate: false)
        }
    }

    public func toggleSnap() {
        if isSnapped {
            unsnap()
        } else {
            snap()
        }
    }

    /// The compact, reader-focused window configuration used while live.
    /// Repeated calls deliberately leave both the saved setup frame and the
    /// current live frame untouched.
    public func enterLiveLayout() {
        guard !isLiveLayout, let window = currentWindow else { return }

        setupFrameBeforeLive = window.frame
        AppPreferences.shared.pendingSetupFrame = window.frame
        isLiveLayout = true
        window.minSize = minimumSize

        guard let screen = screenContaining(window) else { return }
        let targetFrame: NSRect
        if isSnapped {
            targetFrame = snappedFrame(for: Self.liveTargetSize, on: screen)
        } else {
            let targetSize = constrainedSize(Self.liveTargetSize, on: screen)
            targetFrame = constrainedFrame(
                NSRect(
                    x: window.frame.midX - targetSize.width / 2.0,
                    y: window.frame.midY - targetSize.height / 2.0,
                    width: targetSize.width,
                    height: targetSize.height
                ),
                on: screen
            )
        }
        window.setFrame(targetFrame, display: true, animate: false)
    }

    /// Restores the roomy setup window after leaving live mode. Repeated calls
    /// are no-ops so a second exit cannot overwrite a user's restored frame.
    public func exitLiveLayout() {
        guard isLiveLayout, let window = currentWindow else { return }

        let setupFrame = setupFrameBeforeLive ?? window.frame
        isLiveLayout = false
        window.minSize = minimumSize

        guard let screen = screenContaining(window) else {
            setupFrameBeforeLive = nil
            return
        }
        let restoredFrame = isSnapped
            ? snappedFrame(for: setupFrame.size, on: screen)
            : constrainedFrame(setupFrame, on: screen)
        window.setFrame(restoredFrame, display: true, animate: false)
        setupFrameBeforeLive = nil
        AppPreferences.shared.clearPendingSetupFrame()
    }

    public var minimumSize: NSSize {
        Self.minimumSize(forLiveLayout: isLiveLayout)
    }

    public static func minimumSize(forLiveLayout isLiveLayout: Bool) -> NSSize {
        isLiveLayout ? liveMinimumSize : setupMinimumSize
    }

    /// Pure recovery decision kept separate from AppKit so it can be tested
    /// without a live window. A pending frame always wins; otherwise an old
    /// compact autosave must be expanded back into a Setup-sized window.
    public static func shouldRestoreSetupFrame(
        pendingSetupFrame: CGRect?,
        autosavedFrame: CGRect
    ) -> Bool {
        pendingSetupFrame != nil ||
            autosavedFrame.width < setupMinimumSize.width ||
            autosavedFrame.height < setupMinimumSize.height
    }

    public func snap() {
        guard let window = currentWindow else { return }
        guard let targetScreen = screenContaining(window) else { return }

        let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        activeDisplayID = displayID
        AppPreferences.shared.cameraSnapDisplayID = displayID
        AppPreferences.shared.isCameraSnapped = true
        isSnapped = true

        let minimum = minimumSize
        let maxAllowedWidth = targetScreen.visibleFrame.width - 24

        var currentWidth = window.frame.width
        if currentWidth < minimum.width { currentWidth = minimum.width }
        if currentWidth > maxAllowedWidth { currentWidth = maxAllowedWidth }

        var currentHeight = window.frame.height
        if currentHeight < minimum.height { currentHeight = minimum.height }
        let maxAllowedHeight = targetScreen.visibleFrame.height - 16
        if currentHeight > maxAllowedHeight { currentHeight = maxAllowedHeight }

        let targetFrame = snappedFrame(
            for: NSSize(width: currentWidth, height: currentHeight),
            on: targetScreen
        )

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            window.setFrame(targetFrame, display: true, animate: false)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    public func unsnap() {
        guard isSnapped else { return }
        isSnapped = false
        AppPreferences.shared.isCameraSnapped = false
        AppPreferences.shared.cameraSnapDisplayID = nil
        activeDisplayID = nil
    }

    public func handleWindowDidMoveAway() {
        guard isSnapped else { return }
        guard let window = currentWindow, let screen = screenContaining(window) else {
            unsnap()
            return
        }
        let (anchorX, anchorY) = computeCameraAnchor(for: screen)
        let dx = abs(window.frame.midX - anchorX)
        let dy = abs(window.frame.maxY - anchorY)
        // If moved more than 6pt away from the camera anchor, user intentionally dragged it away
        if dx > 6.0 || dy > 6.0 {
            unsnap()
        }
    }

    public func handleDisplayChange() {
        guard isSnapped, currentWindow != nil else { return }
        reapplySnap(animate: false)
    }

    public func reapplySnap(animate: Bool) {
        guard let window = currentWindow else { return }

        // Find display matching saved display ID if possible
        var targetScreen: NSScreen?
        if let savedID = activeDisplayID {
            targetScreen = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == savedID
            }
        }
        if targetScreen == nil {
            targetScreen = screenContaining(window) ?? NSScreen.main
        }
        guard let screen = targetScreen else { return }

        let targetFrame = snappedFrame(for: window.frame.size, on: screen)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate || reduceMotion {
            window.setFrame(targetFrame, display: true, animate: false)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    /// Computes (cameraAnchorX, cameraAnchorY) for a given NSScreen
    public func computeCameraAnchor(for screen: NSScreen) -> (CGFloat, CGFloat) {
        let anchorX: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            // Screen has camera notch: center is between left area maxX and right area minX
            anchorX = (leftArea.maxX + rightArea.minX) / 2.0
        } else {
            // Non-notched display: use screen horizontal midpoint
            anchorX = screen.frame.midX
        }

        // Top edge placed at screen's usable top edge with an 8 pt breathing gap below menu bar/camera area
        let anchorY = screen.visibleFrame.maxY - 8.0

        return (anchorX, anchorY)
    }

    /// Finds the screen containing the largest portion of the window
    public func screenContaining(_ window: NSWindow) -> NSScreen? {
        let windowFrame = window.frame
        var bestScreen: NSScreen?
        var maxArea: CGFloat = 0.0

        for screen in NSScreen.screens {
            let intersection = windowFrame.intersection(screen.frame)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > maxArea {
                    maxArea = area
                    bestScreen = screen
                }
            }
        }

        return bestScreen ?? window.screen ?? NSScreen.main
    }

    /// Calculates symmetric live-resize frame satisfying midX == anchorX and maxY == anchorY
    public func symmetricResizeFrame(
        proposedFrame: NSRect,
        mouseLocation: NSPoint,
        screen: NSScreen
    ) -> NSRect {
        let (anchorX, anchorY) = computeCameraAnchor(for: screen)
        let minimum = minimumSize
        let maxAllowedWidth = screen.visibleFrame.width - 24
        let maxAllowedHeight = screen.visibleFrame.height - 16

        // Symmetrically expand width from anchor centerline: width = 2 * abs(pointerX - anchorX)
        let halfWidth = abs(mouseLocation.x - anchorX)
        var newWidth = max(minimum.width, halfWidth * 2.0)
        newWidth = min(newWidth, maxAllowedWidth)

        // Keep top edge pinned at anchorY, height grows downward
        var newHeight = max(minimum.height, anchorY - mouseLocation.y)
        newHeight = min(newHeight, maxAllowedHeight)

        let newOriginX = anchorX - (newWidth / 2.0)
        let newOriginY = anchorY - newHeight

        return NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight)
    }

    private func snappedFrame(for requestedSize: NSSize, on screen: NSScreen) -> NSRect {
        let (anchorX, anchorY) = computeCameraAnchor(for: screen)
        let size = constrainedSize(requestedSize, on: screen)
        return NSRect(
            x: anchorX - size.width / 2.0,
            y: anchorY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func constrainedSize(_ requestedSize: NSSize, on screen: NSScreen) -> NSSize {
        let maximum = NSSize(
            width: max(0, screen.visibleFrame.width - 24),
            height: max(0, screen.visibleFrame.height - 16)
        )
        let minimum = minimumSize
        return NSSize(
            width: min(maximum.width, max(minimum.width, requestedSize.width)),
            height: min(maximum.height, max(minimum.height, requestedSize.height))
        )
    }

    private func constrainedFrame(_ requestedFrame: NSRect, on screen: NSScreen) -> NSRect {
        let size = constrainedSize(requestedFrame.size, on: screen)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 8)
        let maxX = bounds.maxX - size.width
        let maxY = bounds.maxY - size.height
        return NSRect(
            x: min(max(bounds.minX, requestedFrame.origin.x), maxX),
            y: min(max(bounds.minY, requestedFrame.origin.y), maxY),
            width: size.width,
            height: size.height
        )
    }
}
