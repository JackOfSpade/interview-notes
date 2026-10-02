import XCTest
import SwiftUI
import AppKit
@testable import Rehearse

@MainActor
final class LiveModeRenderTests: XCTestCase {
    func testQuestionSelectionRendersAtCompactLiveSizes() throws {
        let questions = [
            Question(
                prompt: "Tell me about a time you brought clarity to an ambiguous problem.",
                situation: "The team had several competing definitions of success.",
                task: "Create a clear path forward.",
                action: "I aligned the group around one measurable decision.",
                result: "We shipped on time with shared ownership."
            ),
            Question(
                prompt: "Why are you interested in this role right now?",
                answerFormat: .plain,
                plainAnswer: "This role brings together the product and systems work I do best."
            ),
            Question(prompt: "What would you want to learn in your first ninety days?")
        ]

        for size in [CGSize(width: 360, height: 240), CGSize(width: 520, height: 360)] {
            let view = LiveModeView(
                questions: questions,
                initialQuestionID: questions[1].id,
                onExit: { _ in }
            )
            .frame(width: size.width, height: size.height)

            let image = try render(view, at: size)
            XCTAssertEqual(image.size.width, size.width, accuracy: 1)
            XCTAssertEqual(image.size.height, size.height, accuracy: 1)

            if let snapshotDirectory = ProcessInfo.processInfo.environment["REHEARSE_SNAPSHOT_DIR"] {
                try writePNG(
                    image,
                    to: URL(fileURLWithPath: snapshotDirectory, isDirectory: true),
                    fileName: "live-question-selection-\(Int(size.width)).png"
                )
            }
        }

        for size in [CGSize(width: 360, height: 240), CGSize(width: 520, height: 360)] {
            let view = LiveModeView(
                questions: questions,
                initialQuestionID: questions[0].id,
                startsOnAnswer: true,
                onExit: { _ in }
            )
            .frame(width: size.width, height: size.height)

            let image = try render(view, at: size)
            XCTAssertEqual(image.size.width, size.width, accuracy: 1)
            XCTAssertEqual(image.size.height, size.height, accuracy: 1)

            if let snapshotDirectory = ProcessInfo.processInfo.environment["REHEARSE_SNAPSHOT_DIR"] {
                try writePNG(
                    image,
                    to: URL(fileURLWithPath: snapshotDirectory, isDirectory: true),
                    fileName: "live-answer-\(Int(size.width)).png"
                )
            }
        }
    }

    func testEmptyAnswerRendersWithoutPlaceholderContent() throws {
        let question = Question(prompt: "What would you want to learn in your first ninety days?")
        let size = CGSize(width: 360, height: 240)
        let view = LiveModeView(
            questions: [question],
            initialQuestionID: question.id,
            startsOnAnswer: true,
            onExit: { _ in }
        )
        .frame(width: size.width, height: size.height)

        let image = try render(view, at: size)
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1)
        try assertBodyIsBlank(in: image, topInset: 5, bottomInset: 55)

        if let snapshotDirectory = ProcessInfo.processInfo.environment["REHEARSE_SNAPSHOT_DIR"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: snapshotDirectory, isDirectory: true),
                fileName: "live-empty-answer.png"
            )
        }
    }

    func testShortAnswerKeepsOneLineLeadInWithoutVerticalCentering() throws {
        let question = Question(
            prompt: "Tell me about a difficult decision.",
            answerFormat: .plain,
            plainAnswer: "I clarified the trade-offs, aligned the team, and made the decision."
        )
        let size = CGSize(width: 420, height: 400)
        let view = LiveModeView(
            questions: [question],
            initialQuestionID: question.id,
            startsOnAnswer: true,
            onExit: { _ in }
        )
        .frame(width: size.width, height: size.height)

        let image = try render(view, at: size)
        if let snapshotDirectory = ProcessInfo.processInfo.environment["REHEARSE_SNAPSHOT_DIR"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: snapshotDirectory, isDirectory: true),
                fileName: "live-short-answer-one-line-lead-in.png"
            )
        }
        let firstInkRow = try XCTUnwrap(
            firstContrastingInkRow(in: image, bodyTopInset: 4, bodyBottomInset: 64),
            "Expected the short prepared answer to render in the answer body."
        )

        // `bitmapImageRepForCachingDisplay` retains the hosting view's
        // top-left coordinate system. The 21-point text row and line spacing
        // produce first ink at row 36 in this renderer. Keep roughly one line
        // of readable lead-in, while rejecting the old quarter-height /
        // vertically centered placement.
        XCTAssertGreaterThanOrEqual(
            firstInkRow,
            28,
            "A short prepared answer needs one readable line of lead-in above it."
        )
        XCTAssertLessThan(
            firstInkRow,
            72,
            "A short prepared answer must remain near the top instead of being vertically centered."
        )
    }

    func testIdleTeleprompterDoesNotReachEndAfterLayout() {
        let completion = TeleprompterCompletionRecorder()
        let size = CGSize(width: 360, height: 240)
        let stage = TeleprompterStageView(
            text: "Ready",
            wordCount: 1,
            isPlaying: .constant(false),
            wpm: 200,
            onReachedEnd: { completion.count += 1 }
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: stage)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        // At 200 WPM, a one-word answer's old unguarded timer would traverse
        // its 0.3-second duration before this wait completes.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(completion.count, 0, "An idle teleprompter must not auto-scroll to its end.")
    }

    func testPlayingShortTeleprompterRespectsMotionPreferenceAfterLayout() {
        let playback = TeleprompterPlaybackRecorder(isPlaying: true)
        let size = CGSize(width: 360, height: 240)
        let stage = TeleprompterStageView(
            text: "Ready",
            wordCount: 1,
            isPlaying: Binding(
                get: { playback.isPlaying },
                set: { playback.isPlaying = $0 }
            ),
            wpm: 200,
            onReachedEnd: { playback.completionCount += 1 }
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: stage)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // The stage deliberately turns playback off rather than starting
            // an automatic timer when the system asks to reduce motion. Give
            // the initial layout and preference propagation a run-loop turn,
            // then verify that this accessibility behavior does not report a
            // synthetic completion.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(playback.completionCount, 0)
        } else {
            // The timer starts after the layout preference measures the text.
            // Wait for that observable completion rather than assuming the
            // preference has propagated within one fixed render-loop interval
            // on every hosted macOS image.
            let deadline = Date().addingTimeInterval(2)
            while playback.completionCount == 0 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(playback.completionCount, 1)
        }
        XCTAssertFalse(playback.isPlaying)
    }

    private func assertBodyIsBlank(
        in image: NSImage,
        topInset: Int,
        bottomInset: Int
    ) throws {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let reference = bitmap.colorAt(
                x: bitmap.pixelsWide / 2,
                y: bitmap.pixelsHigh / 2
              )?.usingColorSpace(.deviceRGB) else {
            throw CocoaError(.coderInvalidValue)
        }

        for y in stride(from: topInset, to: bitmap.pixelsHigh - bottomInset, by: 5) {
            for x in stride(from: 5, to: bitmap.pixelsWide - 5, by: 5) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let largestDifference = max(
                    abs(color.redComponent - reference.redComponent),
                    abs(color.greenComponent - reference.greenComponent),
                    abs(color.blueComponent - reference.blueComponent),
                    abs(color.alphaComponent - reference.alphaComponent)
                )
                if largestDifference > 0.01 {
                    return XCTFail("Expected the empty-answer body to be blank at (\(x), \(y))")
                }
            }
        }
    }

    /// Finds the first row containing enough answer-text ink to distinguish
    /// glyphs from normal antialiasing. The requested region excludes the
    /// footer and divider, so its only meaningful contrasting pixels are the
    /// prepared answer itself. `NSBitmapImageRep` rows here use the cached
    /// hosting view's top-left coordinate orientation.
    private func firstContrastingInkRow(
        in image: NSImage,
        bodyTopInset: Int,
        bodyBottomInset: Int
    ) throws -> Int? {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let background = bitmap.colorAt(
                x: 4,
                y: max(bodyTopInset, (bitmap.pixelsHigh - bodyBottomInset) / 2)
              )?.usingColorSpace(.deviceRGB) else {
            throw CocoaError(.coderInvalidValue)
        }

        let yRange = max(0, bodyTopInset)..<max(bodyTopInset, bitmap.pixelsHigh - bodyBottomInset)
        let xRange = 12..<max(12, bitmap.pixelsWide - 12)
        for y in yRange {
            var contrastingPixels = 0
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let difference = max(
                    abs(color.redComponent - background.redComponent),
                    abs(color.greenComponent - background.greenComponent),
                    abs(color.blueComponent - background.blueComponent)
                )
                if difference > 0.10 {
                    contrastingPixels += 1
                    if contrastingPixels >= 10 {
                        return y
                    }
                }
            }
        }
        return nil
    }

    private func render<Content: View>(_ view: Content, at size: CGSize) throws -> NSImage {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func writePNG(_ image: NSImage, to directory: URL, fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode Live selection snapshot")
        }
        try png.write(to: directory.appendingPathComponent(fileName))
    }

}

@MainActor
private final class TeleprompterCompletionRecorder {
    var count = 0
}

@MainActor
private final class TeleprompterPlaybackRecorder {
    var isPlaying: Bool
    var completionCount = 0

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }
}
