import XCTest
import SwiftData
@testable import Rehearse

@MainActor
final class ModelTests: XCTestCase {
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

    func testInterviewCreationAndTitle() {
        let interview = Interview(company: "Stripe", role: "Product Designer")
        context.insert(interview)

        XCTAssertEqual(interview.company, "Stripe")
        XCTAssertEqual(interview.role, "Product Designer")
        XCTAssertEqual(interview.title, "Stripe — Product Designer")
    }

    func testQuestionPropertiesAndStarFormatting() {
        let question = Question(
            prompt: "Tell me about a time you led a project.",
            category: .leadership,
            talkingPoints: ["Point 1", "Point 2"],
            answerFormat: .star,
            situation: "The system was slow.",
            task: "Optimize query latency.",
            action: "Introduced Redis caching.",
            result: "Latency decreased by 40%."
        )
        context.insert(question)

        XCTAssertEqual(question.category, .leadership)
        XCTAssertEqual(question.talkingPoints.count, 2)
        XCTAssertEqual(question.confidence, .unrated)
        XCTAssertTrue(question.hasNonEmptyAnswer)

        let expectedText = "Situation: The system was slow.\n\nTask: Optimize query latency.\n\nAction: Introduced Redis caching.\n\nResult: Latency decreased by 40%."
        XCTAssertEqual(question.fullAnswerDisplayText, expectedText)
        XCTAssertGreaterThan(question.wordCount, 10)
    }

    func testFullAnswerDisplayIgnoresWhitespaceOnlyFields() {
        let starQuestion = Question(
            prompt: "Whitespace",
            answerFormat: .star,
            situation: "   \n",
            task: "  Useful task  "
        )
        XCTAssertEqual(starQuestion.fullAnswerDisplayText, "Task: Useful task")

        let outlineQuestion = Question(
            prompt: "Outline",
            talkingPoints: ["  First point  ", "   "],
            answerFormat: .outline,
            plainAnswer: " \n "
        )
        XCTAssertEqual(outlineQuestion.fullAnswerDisplayText, "• First point")

        let plainQuestion = Question(
            prompt: "Plain",
            answerFormat: .plain,
            plainAnswer: "  Prepared answer  "
        )
        XCTAssertEqual(plainQuestion.fullAnswerDisplayText, "Prepared answer")
    }

    func testCascadeDeletion() throws {
        let interview = Interview(company: "Apple", role: "Software Engineer")
        context.insert(interview)

        let q1 = Question(prompt: "Q1", interview: interview)
        let q2 = Question(prompt: "Q2", interview: interview)
        context.insert(q1)
        context.insert(q2)

        let attempt = PracticeAttempt(rating: .good, question: q1)
        context.insert(attempt)

        let unrelatedInterview = Interview(company: "Figma", role: "Product Designer")
        let unrelatedQuestion = Question(prompt: "Keep me", interview: unrelatedInterview)
        context.insert(unrelatedInterview)
        context.insert(unrelatedQuestion)

        try context.save()

        // Verify count before deletion
        var questionDescriptor = FetchDescriptor<Question>()
        var questions = try context.fetch(questionDescriptor)
        XCTAssertEqual(questions.count, 3)

        // Delete interview
        context.delete(interview)
        try context.save()

        // Verify questions were cascade-deleted
        questionDescriptor = FetchDescriptor<Question>()
        questions = try context.fetch(questionDescriptor)
        XCTAssertEqual(questions.map(\.prompt), ["Keep me"])

        // Verify attempts were cascade-deleted
        let attemptDescriptor = FetchDescriptor<PracticeAttempt>()
        let attempts = try context.fetch(attemptDescriptor)
        XCTAssertEqual(attempts.count, 0)

        let interviews = try context.fetch(FetchDescriptor<Interview>())
        XCTAssertEqual(interviews.map(\.title), ["Figma — Product Designer"])
    }
}
