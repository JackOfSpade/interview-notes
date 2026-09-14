import XCTest
import SwiftUI
import AppKit
@testable import Rehearse

@MainActor
final class AnswerEditorInputTests: XCTestCase {
    func testPlainAnswerEditorInsertsNewlineWhenReturnIsPressed() throws {
        let answer = AnswerTextBox(value: "First line")
        let input = PlainAnswerTextEditor(text: Binding(
            get: { answer.value },
            set: { answer.value = $0 }
        ))
        let hostingView = NSHostingView(
            rootView: input
                .frame(width: 700, height: 500)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(
            findTextView(in: hostingView),
            "Plain answers must use an NSTextView so Return inserts a line break."
        )
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        textView.insertNewline(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(answer.value, "First line\n")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: "First line\n".utf16.count, length: 0),
            "Return should leave a collapsed insertion point, not select the answer."
        )
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}

@MainActor
private final class AnswerTextBox {
    var value: String

    init(value: String) {
        self.value = value
    }
}
