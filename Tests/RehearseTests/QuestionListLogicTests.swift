import XCTest
import SwiftData
@testable import Rehearse

@MainActor
final class QuestionListLogicTests: XCTestCase {
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

    func testNearestSelectionAfterDeletion() {
        let q1 = Question(prompt: "Question 1", sortIndex: 0)
        let q2 = Question(prompt: "Question 2", sortIndex: 1)
        let q3 = Question(prompt: "Question 3", sortIndex: 2)

        context.insert(q1)
        context.insert(q2)
        context.insert(q3)

        let list = [q1, q2, q3]
        // Delete q2 (middle element at index 1)
        let indexToDelete = 1
        let nextIndex = indexToDelete + 1 < list.count ? indexToDelete + 1 : indexToDelete - 1
        let selectedAfterDelete = list[nextIndex]
        XCTAssertEqual(selectedAfterDelete.id, q3.id)

        // Delete last element in a 2-element list [q1, q3]
        let list2 = [q1, q3]
        let deleteLastIndex = 1
        let fallbackIndex = deleteLastIndex + 1 < list2.count ? deleteLastIndex + 1 : deleteLastIndex - 1
        XCTAssertEqual(list2[fallbackIndex].id, q1.id)
    }

    func testSelectionPolicyPreservesUnrelatedSelectionAndChoosesNearestNeighbor() {
        let firstID = UUID()
        let middleID = UUID()
        let lastID = UUID()
        let ids = [firstID, middleID, lastID]

        XCTAssertEqual(
            QuestionListSelectionPolicy.selection(
                afterDeleting: lastID,
                currentSelection: firstID,
                orderedQuestionIDs: ids
            ),
            firstID,
            "Deleting an unselected row must not replace the active editor"
        )
        XCTAssertEqual(
            QuestionListSelectionPolicy.selection(
                afterDeleting: middleID,
                currentSelection: middleID,
                orderedQuestionIDs: ids
            ),
            lastID
        )
        XCTAssertEqual(
            QuestionListSelectionPolicy.selection(
                afterDeleting: lastID,
                currentSelection: lastID,
                orderedQuestionIDs: ids
            ),
            middleID
        )
        XCTAssertNil(
            QuestionListSelectionPolicy.selection(
                afterDeleting: firstID,
                currentSelection: firstID,
                orderedQuestionIDs: [firstID]
            )
        )
    }

    func testEditorIdentityIsStableForMaterializationButScopedToInterview() {
        let parent = Interview(company: "Shared", role: "Questions")
        let firstChild = Interview(company: "First", role: "Role")
        let secondChild = Interview(company: "Second", role: "Role")
        firstChild.parentInterview = parent
        secondChild.parentInterview = parent
        let source = Question(prompt: "Shared question", interview: parent)
        [parent, firstChild, secondChild].forEach(context.insert)
        context.insert(source)

        let beforeMaterialization = QuestionEditorIdentity.resolve(
            selection: .interview(firstChild.id),
            currentInterview: firstChild,
            question: source
        )
        let override = firstChild.materializeQuestionOverride(for: source)
        context.insert(override)
        let afterMaterialization = QuestionEditorIdentity.resolve(
            selection: .interview(firstChild.id),
            currentInterview: firstChild,
            question: override
        )
        XCTAssertEqual(beforeMaterialization, afterMaterialization)

        XCTAssertNotEqual(
            beforeMaterialization,
            QuestionEditorIdentity.resolve(
                selection: .interview(parent.id),
                currentInterview: parent,
                question: source
            )
        )
        XCTAssertNotEqual(
            beforeMaterialization,
            QuestionEditorIdentity.resolve(
                selection: .interview(secondChild.id),
                currentInterview: secondChild,
                question: source
            )
        )
        XCTAssertNotEqual(
            beforeMaterialization,
            QuestionEditorIdentity.resolve(
                selection: .all,
                currentInterview: nil,
                question: source
            )
        )
    }

    func testLateEditorCallbackCannotMaterializeIntoNewlySelectedSibling() {
        let parent = Interview(company: "Shared", role: "Questions")
        let firstChild = Interview(company: "First", role: "Role")
        let secondChild = Interview(company: "Second", role: "Role")
        firstChild.parentInterview = parent
        secondChild.parentInterview = parent
        let source = Question(prompt: "Shared question", interview: parent)
        [parent, firstChild, secondChild].forEach(context.insert)
        context.insert(source)

        var activeSelection = SidebarSelection.interview(firstChild.id)
        var currentInterviewID: UUID? = firstChild.id
        let activeQuestionID: UUID? = source.id
        var remappedQuestionID: UUID?
        let retainedFirstChildResolver = InheritedQuestionEditingCoordinator.resolver(
            targetInterview: firstChild,
            renderedQuestionID: source.id,
            modelContext: context,
            activeSelection: { activeSelection },
            currentInterviewID: { currentInterviewID },
            activeQuestionID: { activeQuestionID },
            onSelectionRemap: { remappedQuestionID = $0 }
        )

        // Simulate navigation completing before the old TextField/IME sends
        // its final setter callback.
        activeSelection = .interview(secondChild.id)
        currentInterviewID = secondChild.id

        XCTAssertNil(retainedFirstChildResolver(source))
        XCTAssertTrue(firstChild.questions.isEmpty)
        XCTAssertTrue(secondChild.questions.isEmpty)
        XCTAssertNil(remappedQuestionID)

        activeSelection = .interview(firstChild.id)
        currentInterviewID = firstChild.id
        let editable = retainedFirstChildResolver(source)
        XCTAssertEqual(editable?.interview?.id, firstChild.id)
        XCTAssertEqual(firstChild.questions.map(\.id), [editable?.id].compactMap { $0 })
        XCTAssertTrue(secondChild.questions.isEmpty)
        XCTAssertEqual(remappedQuestionID, editable?.id)
    }

    func testLateEditorAndSourceCallbacksAreRejectedAfterSelectingAnotherQuestion() {
        let parent = Interview(company: "Shared", role: "Questions")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = parent
        let first = Question(prompt: "First", sortIndex: 0, interview: parent)
        let second = Question(prompt: "Second", sortIndex: 1, interview: parent)
        [parent, child].forEach(context.insert)
        [first, second].forEach(context.insert)

        var activeQuestionID: UUID? = first.id
        var remappedQuestionID: UUID?
        let retainedFirstResolver = InheritedQuestionEditingCoordinator.resolver(
            targetInterview: child,
            renderedQuestionID: first.id,
            modelContext: context,
            activeSelection: { .interview(child.id) },
            currentInterviewID: { child.id },
            activeQuestionID: { activeQuestionID },
            onSelectionRemap: { remappedQuestionID = $0 }
        )

        activeQuestionID = second.id

        XCTAssertNil(retainedFirstResolver(first))
        XCTAssertTrue(child.questions.isEmpty)
        XCTAssertNil(remappedQuestionID)
        XCTAssertNil(
            InheritedQuestionSourceCoordinator.destination(
                for: first,
                renderedQuestionID: first.id,
                sourceScope: child,
                activeSelection: .interview(child.id),
                currentInterviewID: child.id,
                activeQuestionID: activeQuestionID
            )
        )

        let currentDestination = InheritedQuestionSourceCoordinator.destination(
            for: second,
            renderedQuestionID: second.id,
            sourceScope: child,
            activeSelection: .interview(child.id),
            currentInterviewID: child.id,
            activeQuestionID: activeQuestionID
        )
        XCTAssertEqual(
            currentDestination,
            QuestionSourceDestination(interviewID: parent.id, questionID: second.id)
        )

        let replacementParent = Interview(company: "Replacement", role: "Questions")
        let replacement = Question(prompt: "Replacement question", interview: replacementParent)
        context.insert(replacementParent)
        context.insert(replacement)
        child.parentInterview = replacementParent
        activeQuestionID = first.id

        XCTAssertNil(
            retainedFirstResolver(first),
            "A still-selected but no-longer-visible source must not be materialized after reparenting"
        )
        XCTAssertTrue(child.questions.isEmpty)
    }

    func testInheritedSourceTitleNeverUsesOverrideOwnerAsItsSource() {
        let parent = Interview(company: "Shared", role: "Questions")
        let child = Interview(company: "Acme", role: "Designer")
        let source = Question(prompt: "Shared", interview: parent)
        let override = Question(
            prompt: "Customized",
            overrideSourceQuestionID: source.id,
            interview: child
        )

        XCTAssertEqual(
            InheritedQuestionPresentation.sourceTitle(
                question: source,
                inheritedFrom: nil
            ),
            parent.title
        )
        XCTAssertNil(
            InheritedQuestionPresentation.sourceTitle(
                question: override,
                inheritedFrom: nil
            ),
            "A child-owned override must not label its child owner as the source"
        )
        XCTAssertEqual(
            InheritedQuestionPresentation.sourceTitle(
                question: override,
                inheritedFrom: parent
            ),
            parent.title
        )
    }

    func testConfidenceShortcutsAndColors() {
        XCTAssertEqual(Confidence.again.shortcutNumber, 1)
        XCTAssertEqual(Confidence.good.shortcutNumber, 2)
        XCTAssertEqual(Confidence.confident.shortcutNumber, 3)
        XCTAssertNil(Confidence.unrated.shortcutNumber)

        XCTAssertEqual(Confidence.again.label, "Again")
        XCTAssertEqual(Confidence.good.label, "Good")
        XCTAssertEqual(Confidence.confident.label, "Confident")
    }

    func testAnswerHasContentChecks() {
        let emptyQ = Question(prompt: "Empty Answer")
        XCTAssertFalse(emptyQ.hasNonEmptyAnswer)

        let talkingPointsQ = Question(prompt: "Has Talking Point", talkingPoints: ["Cue 1"])
        XCTAssertTrue(talkingPointsQ.hasNonEmptyAnswer)

        let starQ = Question(prompt: "Has Situation", situation: "Context")
        XCTAssertTrue(starQ.hasNonEmptyAnswer)

        let plainQ = Question(prompt: "Has Plain Text", plainAnswer: "Some notes")
        XCTAssertTrue(plainQ.hasNonEmptyAnswer)
    }

    func testEmptyStateRoutesDoNotCreateDuplicateInterviews() {
        XCTAssertEqual(
            QuestionListEmptyStateRoute.resolve(
                hasCurrentInterview: true,
                hasExistingInterviews: true
            ),
            .addQuestion
        )
        XCTAssertEqual(
            QuestionListEmptyStateRoute.resolve(
                hasCurrentInterview: false,
                hasExistingInterviews: true
            ),
            .selectExistingInterview
        )
        XCTAssertEqual(
            QuestionListEmptyStateRoute.resolve(
                hasCurrentInterview: false,
                hasExistingInterviews: false
            ),
            .createInterview
        )
    }
}
