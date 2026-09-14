import AppKit
import SwiftUI

@MainActor
public final class WindowDelegateHandler: NSObject, NSWindowDelegate {
    public static let shared = WindowDelegateHandler()

    private override init() {
        super.init()
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let wm = WindowManager.shared
        guard wm.isSnapped, let screen = wm.screenContaining(sender) else {
            return frameSize
        }

        let (anchorX, _) = wm.computeCameraAnchor(for: screen)
        let mouseLoc = NSEvent.mouseLocation
        let maxAllowedWidth = screen.visibleFrame.width - 24
        let maxAllowedHeight = screen.visibleFrame.height - 16
        let minimum = wm.minimumSize

        // Symmetrically calculate width based on pointer distance from center
        let halfWidth = abs(mouseLoc.x - anchorX)
        var symmetricWidth = max(minimum.width, halfWidth * 2.0)
        symmetricWidth = min(symmetricWidth, maxAllowedWidth)

        // Only adjust height if user is actually resizing vertically
        var newHeight = frameSize.height
        if abs(frameSize.height - sender.frame.height) > 0.5 {
            newHeight = max(minimum.height, min(frameSize.height, maxAllowedHeight))
        } else {
            newHeight = sender.frame.height
        }

        return NSSize(width: symmetricWidth, height: newHeight)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let wm = WindowManager.shared
        guard wm.isSnapped, let screen = wm.screenContaining(window) else { return }

        let (anchorX, anchorY) = wm.computeCameraAnchor(for: screen)
        let expectedX = anchorX - (window.frame.width / 2.0)
        let expectedY = anchorY - window.frame.height

        if abs(window.frame.origin.x - expectedX) > 0.5 || abs(window.frame.origin.y - expectedY) > 0.5 {
            window.setFrameOrigin(NSPoint(x: expectedX, y: expectedY))
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // If moving during live resize, it's just AppKit frame repositioning
        if window.inLiveResize {
            return
        }
        WindowManager.shared.handleWindowDidMoveAway()
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        WindowManager.shared.unsnap()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        WindowManager.shared.unsnap()
    }
}

public struct WindowAccessor: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = WindowDelegateHandler.shared
                window.setFrameAutosaveName("RehearseMainWindow")
                WindowManager.shared.registerWindow(window)
            }
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, WindowManager.shared.currentWindow !== window {
                window.delegate = WindowDelegateHandler.shared
                window.setFrameAutosaveName("RehearseMainWindow")
                WindowManager.shared.registerWindow(window)
            }
        }
    }
}
