import XCTest
import SwiftUI
import SwiftData
import AppKit
@testable import Rehearse

/// An opt-in render smoke test for inheritance surfaces. Set
/// `REHEARSE_SNAPSHOT_DIR` when running the test to retain the generated
/// PNGs; the test itself uses only an in-memory SwiftData store.
@MainActor
final class InheritedUIRenderTests: XCTestCase {
    private var container: ModelContainer!
    private var master: Interview!
    private var child: Interview!
    private var inheritedQuestion: Question!

    override func setUp() async throws {
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        master = Interview(company: "Shared Interview Bank", role: "Core Questions", sortIndex: 0)
        child = Interview(company: "Northwind Trading Company", role: "Senior Product Designer", sortIndex: 1)
        child.parentInterview = master

        inheritedQuestion = Question(
            prompt: "Tell me about a time you brought clarity to an ambiguous product problem.",
            talkingPoints: ["Align on the decision", "Use a measurable outcome"],
            situation: "The team had competing definitions of success.",
            task: "Create one clear path forward.",
            action: "I facilitated a decision workshop and wrote the brief.",
            result: "We shipped on time with shared ownership.",
            sortIndex: 0,
            interview: master
        )
        let localQuestion = Question(
            prompt: "Why Northwind, and why this design role?",
            answerFormat: .plain,
            plainAnswer: "The role combines systems thinking and customer-focused product work.",
            sortIndex: 0,
            interview: child
        )

        context.insert(master)
        context.insert(child)
        context.insert(inheritedQuestion)
        context.insert(localQuestion)
        try context.save()
    }

    override func tearDown() async throws {
        inheritedQuestion = nil
        child = nil
        master = nil
        container = nil
    }

    func testInheritanceSurfacesRenderAtNormalAndCompactSizes() throws {
        let listSize = CGSize(width: 360, height: 460)
        let list = ChildQuestionListHarness(
            interviewID: child.id,
            selectedQuestionID: inheritedQuestion.id
        )
        .modelContainer(container)
        .frame(width: listSize.width, height: listSize.height)
        _ = try snapshot(list, named: "inheritance-question-list-compact", at: listSize)

        let sheetSize = CGSize(width: 460, height: 520)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let creationSheet = NewInterviewSheet()
                .modelContainer(container)
                .frame(width: sheetSize.width, height: sheetSize.height)
            _ = try snapshot(
                creationSheet,
                named: "inheritance-create-sheet-\(suffix)",
                at: sheetSize,
                appearance: appearance
            )

            let editSheet = NewInterviewSheet(interviewToEdit: child)
                .modelContainer(container)
                .frame(width: sheetSize.width, height: sheetSize.height)
            let image = try snapshot(
                editSheet,
                named: "inheritance-edit-sheet-\(suffix)",
                at: sheetSize,
                appearance: appearance
            )
            assertEditSheetLabelsAreVisible(in: image, appearance: appearance)
        }

        for size in [CGSize(width: 360, height: 420), CGSize(width: 780, height: 620)] {
            let editor = AnswerEditorView(
                question: inheritedQuestion,
                isInherited: true,
                inheritedFrom: master,
                onOpenSource: {},
                onBeginEditing: { [unowned self] source in
                    let existingIDs = Set(child.questions.map(\.id))
                    let editable = child.materializeQuestionOverride(for: source)
                    guard editable.interview?.id == child.id else { return nil }
                    if !existingIDs.contains(editable.id) {
                        container.mainContext.insert(editable)
                    }
                    return editable
                }
            )
            .frame(width: size.width, height: size.height)
            _ = try snapshot(editor, named: "inherited-editable-editor-\(Int(size.width))", at: size)
        }
    }

    private func snapshot<Content: View>(
        _ view: Content,
        named name: String,
        at size: CGSize,
        appearance: NSAppearance.Name = .aqua
    ) throws -> NSImage {
        let image = try render(view, at: size, appearance: appearance)
        XCTAssertEqual(image.size.width, size.width, accuracy: 1, name)
        XCTAssertEqual(image.size.height, size.height, accuracy: 1, name)

        if let snapshotDirectory = ProcessInfo.processInfo.environment["REHEARSE_SNAPSHOT_DIR"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: snapshotDirectory, isDirectory: true),
                fileName: "\(name).png"
            )
        }
        return image
    }

    /// Snapshot dimensions alone can pass after a native `Form` rebuild while
    /// labels have not yet composited. Verify ink in the areas occupied by the
    /// edit form's three labels and date toggle in both colour schemes.
    private func assertEditSheetLabelsAreVisible(
        in image: NSImage,
        appearance: NSAppearance.Name
    ) {
        let labelRegions = [
            ("Company", CGRect(x: 130, y: 204, width: 68, height: 20)),
            ("Role", CGRect(x: 162, y: 236, width: 36, height: 20)),
            ("Inheritance", CGRect(x: 56, y: 268, width: 142, height: 20)),
            ("Target date", CGRect(x: 198, y: 295, width: 130, height: 20))
        ]

        for (name, region) in labelRegions {
            XCTAssertGreaterThan(
                contrastingPixelCount(in: image, topLeftRegion: region),
                12,
                "Expected visible \(name) label in the \(appearance.rawValue) edit sheet render"
            )
        }
    }

    private func contrastingPixelCount(in image: NSImage, topLeftRegion: CGRect) -> Int {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return 0
        }

        let xRange = max(0, Int(topLeftRegion.minX))..<min(bitmap.pixelsWide, Int(topLeftRegion.maxX))
        // `bitmapImageRepForCachingDisplay` preserves the hosting view's
        // top-left coordinate system, matching the screenshot coordinates.
        let lowerY = max(0, Int(topLeftRegion.minY))
        let upperY = min(bitmap.pixelsHigh, Int(topLeftRegion.maxY))
        guard !xRange.isEmpty, lowerY < upperY else { return 0 }

        var count = 0
        for y in lowerY..<upperY {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let difference = max(
                    abs(color.redComponent - background.redComponent),
                    abs(color.greenComponent - background.greenComponent),
                    abs(color.blueComponent - background.blueComponent)
                )
                if difference > 0.12 {
                    count += 1
                }
            }
        }
        return count
    }

    private func render<Content: View>(
        _ view: Content,
        at size: CGSize,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let colorScheme: ColorScheme = appearance == .aqua ? .light : .dark
        let canvasColor: Color = appearance == .aqua ? .white : .black
        let hostingView = NSHostingView(rootView: ZStack {
            canvasColor
            view
        }
        .preferredColorScheme(colorScheme))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: appearance)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .white : .black
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        // `List` materializes its rows on the next AppKit run-loop turn. This
        // remains local to the ephemeral test window and avoids capturing the
        // list shell before its inherited/local sections have been populated.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        window.orderOut(nil)
        return image
    }

    private func writePNG(
        _ image: NSImage,
        to directory: URL,
        fileName: String
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode \(fileName)")
        }
        try png.write(to: directory.appendingPathComponent(fileName))
    }
}

private struct ChildQuestionListHarness: View {
    @State private var selection: SidebarSelection
    @State private var selectedQuestionID: UUID?

    init(interviewID: UUID, selectedQuestionID: UUID) {
        _selection = State(initialValue: .interview(interviewID))
        _selectedQuestionID = State(initialValue: selectedQuestionID)
    }

    var body: some View {
        QuestionListView(
            selection: $selection,
            selectedQuestionID: $selectedQuestionID,
            showsInterviewMenu: true,
            onNewInterview: {},
            onEditInterview: { _ in },
            onDeleteInterview: { _ in }
        )
    }
}
