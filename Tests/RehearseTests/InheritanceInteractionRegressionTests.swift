import XCTest
import SwiftData
@testable import Rehearse

/// Exercises the data interactions behind the list's local-only controls.
/// A company set must remain a live projection of its master while mutations
/// to the company's own records never leak back into that master or siblings.
@MainActor
final class InheritanceInteractionRegressionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    func testMasterReorderAndChildLocalChangesRemainIsolated() throws {
        let master = Interview(company: "Core", role: "Shared bank")
        let acme = Interview(company: "Acme", role: "Designer")
        let beta = Interview(company: "Beta", role: "Designer")
        acme.parentInterview = master
        beta.parentInterview = master

        let first = Question(prompt: "Master first", sortIndex: 0, interview: master)
        let second = Question(prompt: "Master second", sortIndex: 1, interview: master)
        let acmeOnly = Question(prompt: "Acme only", sortIndex: 0, interview: acme)
        let betaOnly = Question(prompt: "Beta only", sortIndex: 0, interview: beta)
        [master, acme, beta].forEach(context.insert)
        [first, second, acmeOnly, betaOnly].forEach(context.insert)
        try context.save()

        XCTAssertEqual(acme.effectiveQuestions.map(\.prompt), ["Master first", "Master second", "Acme only"])
        XCTAssertEqual(beta.effectiveQuestions.map(\.prompt), ["Master first", "Master second", "Beta only"])

        // This mirrors a source-set reorder. Descendants must immediately see
        // the new inherited order without copying or changing their locals.
        first.sortIndex = 1
        second.sortIndex = 0
        try context.save()

        XCTAssertEqual(acme.effectiveQuestions.map(\.prompt), ["Master second", "Master first", "Acme only"])
        XCTAssertEqual(beta.effectiveQuestions.map(\.prompt), ["Master second", "Master first", "Beta only"])

        // This mirrors deleting a local question in a child-focused list, then
        // adding a new local question. Neither operation may alter the shared
        // source or a sibling inheriting from it.
        context.delete(acmeOnly)
        try context.save()

        let replacement = Question(
            prompt: "Acme replacement",
            sortIndex: (acme.sortedQuestions.map(\.sortIndex).max() ?? -1) + 1,
            interview: acme
        )
        context.insert(replacement)
        try context.save()

        XCTAssertEqual(master.sortedQuestions.map(\.prompt), ["Master second", "Master first"])
        XCTAssertEqual(acme.effectiveQuestions.map(\.prompt), ["Master second", "Master first", "Acme replacement"])
        XCTAssertEqual(beta.effectiveQuestions.map(\.prompt), ["Master second", "Master first", "Beta only"])
        XCTAssertEqual(master.questions.map(\.id).count, 2)
        XCTAssertEqual(beta.questions.map(\.id), [betaOnly.id])
    }
}
