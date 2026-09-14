import XCTest
import SwiftData
@testable import Rehearse

@MainActor
final class PracticeLogicTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    func testDueForPracticeLogic() {
        let unratedQ = Question(prompt: "Unrated Question", confidence: .unrated)
        context.insert(unratedQ)
        XCTAssertTrue(unratedQ.isDueForPractice)

        let againQ = Question(prompt: "Needs Practice Question", confidence: .again)
        context.insert(againQ)
        XCTAssertTrue(againQ.isDueForPractice)

        let confidentQ = Question(prompt: "Confident Question", confidence: .confident)
        context.insert(confidentQ)
        // Practiced just now
        let freshAttempt = PracticeAttempt(rating: .confident, practicedAt: Date(), question: confidentQ)
        context.insert(freshAttempt)
        confidentQ.practiceAttempts.append(freshAttempt)

        XCTAssertFalse(confidentQ.isDueForPractice)
    }

    func testSampleDataInsertion() throws {
        SampleData.insertSampleData(into: context)

        let interviewDescriptor = FetchDescriptor<Interview>()
        let interviews = try context.fetch(interviewDescriptor)
        XCTAssertEqual(interviews.count, 3)

        let questionDescriptor = FetchDescriptor<Question>()
        let questions = try context.fetch(questionDescriptor)
        XCTAssertGreaterThanOrEqual(questions.count, 6)

        // Verify Stripe questions exist
        let stripe = interviews.first(where: { $0.company == "Stripe" })
        XCTAssertNotNil(stripe)
        XCTAssertEqual(stripe?.questions.count, 4)

        let coreBank = try XCTUnwrap(
            interviews.first(where: { $0.role == "Core Question Bank" })
        )
        XCTAssertEqual(stripe?.parentInterview?.id, coreBank.id)
        XCTAssertEqual(
            Set(coreBank.childInterviews.map(\.id)),
            Set([stripe?.id, interviews.first(where: { $0.company == "Figma" })?.id].compactMap { $0 })
        )
        XCTAssertEqual(stripe?.effectiveQuestions.count, 5)
    }
}
