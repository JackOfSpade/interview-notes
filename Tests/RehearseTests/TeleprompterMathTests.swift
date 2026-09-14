import XCTest
import Combine
@testable import Rehearse

final class TeleprompterMathTests: XCTestCase {
    func testMaximumOffsetLetsShortAndLongAnswersExitTheStage() {
        XCTAssertEqual(
            TeleprompterScrollMath.maximumOffset(contentHeight: 24),
            24,
            "A one-line answer must still be able to scroll fully out of view."
        )
        XCTAssertEqual(TeleprompterScrollMath.maximumOffset(contentHeight: 960), 960)
        XCTAssertEqual(TeleprompterScrollMath.maximumOffset(contentHeight: -1), 0)
    }

    func testDragOffsetUsesGestureStartForCumulativeTranslation() {
        let startOffset: CGFloat = 100
        let maximumOffset: CGFloat = 300

        XCTAssertEqual(
            TeleprompterScrollMath.dragOffset(
                startOffset: startOffset,
                translationHeight: 100,
                maximumOffset: maximumOffset
            ),
            90
        )
        XCTAssertEqual(
            TeleprompterScrollMath.dragOffset(
                startOffset: startOffset,
                translationHeight: 250,
                maximumOffset: maximumOffset
            ),
            75
        )
    }

    func testDragOffsetClampsToScrollableRange() {
        XCTAssertEqual(
            TeleprompterScrollMath.dragOffset(
                startOffset: 20,
                translationHeight: 1_000,
                maximumOffset: 300
            ),
            0
        )
        XCTAssertEqual(
            TeleprompterScrollMath.dragOffset(
                startOffset: 250,
                translationHeight: -1_000,
                maximumOffset: 300
            ),
            300
        )
    }

    func testPreciseWheelScrollUsesSystemDirectionMapping() {
        let startOffset: CGFloat = 100
        let maximumOffset: CGFloat = 300

        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: startOffset,
                scrollingDeltaY: 10,
                hasPreciseDeltas: true,
                coarseRowHeight: 30,
                maximumOffset: maximumOffset
            ),
            90,
            "A positive AppKit scrolling delta moves toward earlier text."
        )
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: startOffset,
                scrollingDeltaY: -10,
                hasPreciseDeltas: true,
                coarseRowHeight: 30,
                maximumOffset: maximumOffset
            ),
            110,
            "A negative AppKit scrolling delta moves toward later text."
        )
    }

    func testPreciseWheelScrollPreservesFractionalPointDeltas() {
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 100,
                scrollingDeltaY: 12.5,
                hasPreciseDeltas: true,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            87.5,
            accuracy: 0.000_001
        )
    }

    func testCoarseWheelScrollScalesNotchesByInjectedRowHeight() {
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 100,
                scrollingDeltaY: 1,
                hasPreciseDeltas: false,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            70
        )
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 100,
                scrollingDeltaY: -1,
                hasPreciseDeltas: false,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            130
        )
    }

    func testWheelScrollClampsAtBothDocumentBounds() {
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 4,
                scrollingDeltaY: 100,
                hasPreciseDeltas: true,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            0
        )
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 296,
                scrollingDeltaY: -100,
                hasPreciseDeltas: true,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            300
        )
    }

    func testZeroWheelDeltaDoesNotMoveTheAnswer() {
        XCTAssertEqual(
            TeleprompterScrollMath.wheelOffset(
                from: 123,
                scrollingDeltaY: 0,
                hasPreciseDeltas: false,
                coarseRowHeight: 30,
                maximumOffset: 300
            ),
            123
        )
    }

    func testManualScrollRequiresARepeatTickBeforeMoving() {
        let startOffset: CGFloat = 120

        for direction in [-1, 1] {
            XCTAssertEqual(
                TeleprompterScrollMath.manualOffset(
                    from: startOffset,
                    direction: direction,
                    stageHeight: 300,
                    maximumOffset: 500,
                    repeatTicks: 0
                ),
                startOffset
            )
        }
    }

    func testManualScrollRepeatMovesInEitherDirectionAndClamps() {
        let downOneTick = TeleprompterScrollMath.manualOffset(
            from: 120,
            direction: 1,
            stageHeight: 300,
            maximumOffset: 500,
            repeatTicks: 1
        )
        let downTenTicks = TeleprompterScrollMath.manualOffset(
            from: 120,
            direction: 1,
            stageHeight: 300,
            maximumOffset: 500,
            repeatTicks: 10
        )
        XCTAssertEqual(downOneTick, 123, accuracy: 0.000_001)
        XCTAssertGreaterThan(downTenTicks, downOneTick)
        XCTAssertEqual(
            TeleprompterScrollMath.manualOffset(
                from: 499,
                direction: 1,
                stageHeight: 300,
                maximumOffset: 500,
                repeatTicks: 10
            ),
            500
        )

        let upOneTick = TeleprompterScrollMath.manualOffset(
            from: 120,
            direction: -1,
            stageHeight: 300,
            maximumOffset: 500,
            repeatTicks: 1
        )
        let upTenTicks = TeleprompterScrollMath.manualOffset(
            from: 120,
            direction: -1,
            stageHeight: 300,
            maximumOffset: 500,
            repeatTicks: 10
        )
        XCTAssertEqual(upOneTick, 117, accuracy: 0.000_001)
        XCTAssertLessThan(upTenTicks, upOneTick)
        XCTAssertEqual(
            TeleprompterScrollMath.manualOffset(
                from: 1,
                direction: -1,
                stageHeight: 300,
                maximumOffset: 500,
                repeatTicks: 10
            ),
            0
        )
    }

    func testScrollStepReflectsCurrentWPMAndScrollRange() {
        let interval: CGFloat = 0.02
        let baseline = TeleprompterScrollMath.scrollStep(
            maximumOffset: 240,
            wordCount: 120,
            wpm: 120,
            interval: interval
        )
        XCTAssertEqual(baseline, 0.08, accuracy: 0.000_001)

        let resizedRange = TeleprompterScrollMath.scrollStep(
            maximumOffset: 120,
            wordCount: 120,
            wpm: 120,
            interval: interval
        )
        XCTAssertEqual(resizedRange, 0.04, accuracy: 0.000_001)

        let fasterWPM = TeleprompterScrollMath.scrollStep(
            maximumOffset: 240,
            wordCount: 120,
            wpm: 240,
            interval: interval
        )
        XCTAssertEqual(fasterWPM, 0.16, accuracy: 0.000_001)
    }

    func testDurationCalculation() {
        let wordCount = 120
        let wpm = 120
        let duration = (Double(wordCount) / Double(wpm)) * 60.0
        XCTAssertEqual(duration, 60.0, accuracy: 0.001)

        let fastWpm = 200
        let fastDuration = (Double(wordCount) / Double(fastWpm)) * 60.0
        XCTAssertEqual(fastDuration, 36.0, accuracy: 0.001)
    }

    func testWordCountCalculation() {
        let text = "This is a five word sentence."
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        XCTAssertEqual(words.count, 6)

        let multiParagraph = """
        Paragraph one with some words.

        Paragraph two with additional details here.
        """
        let count = multiParagraph.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        XCTAssertEqual(count, 11)
    }

    @MainActor
    func testAppPreferencesClamping() {
        let suiteName = "TestDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = AppPreferences(defaults: defaults)
        var publicationCount = 0
        let cancellable = prefs.objectWillChange.sink { _ in
            publicationCount += 1
        }

        prefs.teleprompterWPM = 50
        XCTAssertEqual(prefs.teleprompterWPM, 70) // clamped to min 70

        prefs.teleprompterWPM = 250
        XCTAssertEqual(prefs.teleprompterWPM, 200) // clamped to max 200

        prefs.windowTransparency = -0.5
        XCTAssertEqual(prefs.windowTransparency, 0.0)

        prefs.windowTransparency = 0.9
        XCTAssertEqual(prefs.windowTransparency, 0.4) // clamped to max 0.4
        XCTAssertEqual(publicationCount, 4, "Each assignment should publish once, even when it is clamped.")

        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testAppPreferencesNormalizesPersistedValues() {
        let suiteName = "TestDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(999, forKey: AppPreferences.Keys.teleprompterWPM)
        defaults.set(-1.0, forKey: AppPreferences.Keys.windowTransparency)
        defaults.set(2, forKey: AppPreferences.Keys.teleprompterStartDelay)

        let prefs = AppPreferences(defaults: defaults)

        XCTAssertEqual(prefs.teleprompterWPM, 200)
        XCTAssertEqual(prefs.windowTransparency, 0.0)
        XCTAssertEqual(prefs.teleprompterStartDelay, 3)
        XCTAssertEqual(defaults.integer(forKey: AppPreferences.Keys.teleprompterWPM), 200)
        XCTAssertEqual(defaults.double(forKey: AppPreferences.Keys.windowTransparency), 0.0)
        XCTAssertEqual(defaults.integer(forKey: AppPreferences.Keys.teleprompterStartDelay), 3)
    }
}
