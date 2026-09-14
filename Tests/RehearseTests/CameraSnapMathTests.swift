import XCTest
import AppKit
@testable import Rehearse

@MainActor
final class CameraSnapMathTests: XCTestCase {
    func testSymmetricResizeWidthFormula() {
        let anchorX: CGFloat = 800.0

        // Pointer dragged to right edge at x = 1200
        let pointerRight: CGFloat = 1200.0
        let halfWidthRight = abs(pointerRight - anchorX)
        let widthFromRight = halfWidthRight * 2.0
        XCTAssertEqual(widthFromRight, 800.0)

        // Pointer dragged to left edge at x = 400
        let pointerLeft: CGFloat = 400.0
        let halfWidthLeft = abs(pointerLeft - anchorX)
        let widthFromLeft = halfWidthLeft * 2.0
        XCTAssertEqual(widthFromLeft, 800.0)

        // MidX invariant holds for both
        let originXRight = anchorX - (widthFromRight / 2.0)
        let midXRight = originXRight + (widthFromRight / 2.0)
        XCTAssertEqual(midXRight, anchorX)

        let originXLeft = anchorX - (widthFromLeft / 2.0)
        let midXLeft = originXLeft + (widthFromLeft / 2.0)
        XCTAssertEqual(midXLeft, anchorX)
    }

    func testTopEdgeAnchorInvariant() {
        let anchorY: CGFloat = 900.0
        let height: CGFloat = 600.0
        let originY = anchorY - height
        let maxY = originY + height

        XCTAssertEqual(maxY, anchorY)
    }

    func testMinimumWindowSizeClamping() {
        let anchorX: CGFloat = 500.0
        let anchorY: CGFloat = 800.0
        let pointerX: CGFloat = 510.0 // only 10pt from center -> raw width would be 20

        let halfWidth = abs(pointerX - anchorX)
        let setupMinimum = WindowManager.minimumSize(forLiveLayout: false)
        let clampedWidth = max(setupMinimum.width, halfWidth * 2.0)
        XCTAssertEqual(clampedWidth, setupMinimum.width)

        let pointerY: CGFloat = 790.0 // only 10pt below anchor -> raw height would be 10
        let clampedHeight = max(setupMinimum.height, anchorY - pointerY)
        XCTAssertEqual(clampedHeight, setupMinimum.height)
    }

    func testLiveMinimumWindowSizeIsCompactAndModeAware() {
        let setupMinimum = WindowManager.minimumSize(forLiveLayout: false)
        let liveMinimum = WindowManager.minimumSize(forLiveLayout: true)

        XCTAssertEqual(setupMinimum, WindowManager.setupMinimumSize)
        XCTAssertEqual(liveMinimum, WindowManager.liveMinimumSize)
        XCTAssertLessThan(liveMinimum.width, setupMinimum.width)
        XCTAssertLessThan(liveMinimum.height, setupMinimum.height)
        XCTAssertEqual(WindowManager.liveTargetSize, NSSize(width: 520, height: 360))
    }

    func testSetupFrameRecoveryHandlesPendingAndLegacyCompactAutosaves() {
        let roomyFrame = CGRect(x: 80, y: 60, width: 900, height: 640)
        let compactLiveFrame = CGRect(x: 80, y: 60, width: 520, height: 360)

        XCTAssertTrue(
            WindowManager.shouldRestoreSetupFrame(
                pendingSetupFrame: roomyFrame,
                autosavedFrame: compactLiveFrame
            )
        )
        XCTAssertTrue(
            WindowManager.shouldRestoreSetupFrame(
                pendingSetupFrame: nil,
                autosavedFrame: compactLiveFrame
            )
        )
        XCTAssertFalse(
            WindowManager.shouldRestoreSetupFrame(
                pendingSetupFrame: nil,
                autosavedFrame: roomyFrame
            )
        )
    }
}
