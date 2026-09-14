import Foundation
import XCTest
import SwiftData
@testable import Rehearse

@MainActor
final class InterviewInheritanceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    func testEffectiveQuestionsPrependInheritedQuestionsAndKeepLiveReferences() throws {
        let master = Interview(company: "Core", role: "Master")
        let company = Interview(company: "Acme", role: "Designer")
        company.parentInterview = master

        let laterMasterQuestion = Question(prompt: "Master later", sortIndex: 1, interview: master)
        let firstMasterQuestion = Question(prompt: "Master first", sortIndex: 0, interview: master)
        let companyQuestion = Question(prompt: "Company specific", sortIndex: 0, interview: company)
        [master, company].forEach(context.insert)
        [laterMasterQuestion, firstMasterQuestion, companyQuestion].forEach(context.insert)
        try context.save()

        XCTAssertEqual(master.sortedQuestions.map(\.prompt), ["Master first", "Master later"])
        XCTAssertEqual(company.inheritedQuestions.map(\.prompt), ["Master first", "Master later"])
        XCTAssertEqual(
            company.effectiveQuestions.map(\.prompt),
            ["Master first", "Master later", "Company specific"]
        )
        XCTAssertEqual(company.sortedQuestions.map(\.prompt), ["Company specific"])

        let inheritedReference = try XCTUnwrap(company.effectiveQuestions.first)
        XCTAssertTrue(inheritedReference === firstMasterQuestion)
        firstMasterQuestion.plainAnswer = "Edited once in the master"
        XCTAssertEqual(company.effectiveQuestions.first?.plainAnswer, "Edited once in the master")
    }

    func testSortedQuestionsUsesUUIDAsDeterministicFinalTieBreaker() throws {
        let interview = Interview(company: "Acme", role: "Designer")
        let createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let laterID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterQuestion = Question(
            id: laterID,
            prompt: "Later UUID",
            sortIndex: 0,
            createdAt: createdAt,
            interview: interview
        )
        let earlierQuestion = Question(
            id: earlierID,
            prompt: "Earlier UUID",
            sortIndex: 0,
            createdAt: createdAt,
            interview: interview
        )
        context.insert(interview)
        context.insert(laterQuestion)
        context.insert(earlierQuestion)
        try context.save()

        XCTAssertEqual(
            interview.sortedQuestions.map(\.id),
            [earlierID, laterID]
        )
    }

    func testMultilevelInheritanceAndSiblingSetsStayIndependent() throws {
        let root = Interview(company: "Core", role: "Master")
        let middle = Interview(company: "Platform", role: "Shared")
        middle.parentInterview = root
        let leaf = Interview(company: "Acme", role: "Designer")
        leaf.parentInterview = middle
        let sibling = Interview(company: "Beta", role: "Engineer")
        sibling.parentInterview = root

        let rootQuestion = Question(prompt: "Root", sortIndex: 0, interview: root)
        let middleQuestion = Question(prompt: "Middle", sortIndex: 0, interview: middle)
        let leafQuestion = Question(prompt: "Leaf", sortIndex: 0, interview: leaf)
        let siblingQuestion = Question(prompt: "Sibling", sortIndex: 0, interview: sibling)
        [root, middle, leaf, sibling].forEach(context.insert)
        [rootQuestion, middleQuestion, leafQuestion, siblingQuestion].forEach(context.insert)
        try context.save()

        XCTAssertEqual(leaf.inheritedQuestions.map(\.prompt), ["Root", "Middle"])
        XCTAssertEqual(leaf.effectiveQuestions.map(\.prompt), ["Root", "Middle", "Leaf"])
        XCTAssertEqual(sibling.inheritedQuestions.map(\.prompt), ["Root"])
        XCTAssertEqual(sibling.effectiveQuestions.map(\.prompt), ["Root", "Sibling"])
        XCTAssertEqual(Set(root.childInterviews.map(\.id)), Set([middle.id, sibling.id]))
    }

    func testReparentingUpdatesBothInverseCollectionsWithoutDuplicatingQuestions() throws {
        let firstMaster = Interview(company: "Core", role: "First Master")
        let secondMaster = Interview(company: "Core", role: "Second Master")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = firstMaster

        let firstQuestion = Question(prompt: "First common", interview: firstMaster)
        let secondQuestion = Question(prompt: "Second common", interview: secondMaster)
        let childQuestion = Question(prompt: "Company specific", interview: child)
        [firstMaster, secondMaster, child].forEach(context.insert)
        [firstQuestion, secondQuestion, childQuestion].forEach(context.insert)
        try context.save()

        XCTAssertEqual(child.effectiveQuestions.map(\.prompt), ["First common", "Company specific"])
        XCTAssertEqual(firstMaster.childInterviews.map(\.id), [child.id])

        child.parentInterview = secondMaster
        try context.save()

        XCTAssertTrue(firstMaster.childInterviews.isEmpty)
        XCTAssertEqual(secondMaster.childInterviews.map(\.id), [child.id])
        XCTAssertEqual(child.inheritedQuestions.map(\.prompt), ["Second common"])
        XCTAssertEqual(child.effectiveQuestions.map(\.prompt), ["Second common", "Company specific"])
        XCTAssertEqual(child.sortedQuestions.map(\.prompt), ["Company specific"])

        child.parentInterview = nil
        try context.save()

        XCTAssertTrue(secondMaster.childInterviews.isEmpty)
        XCTAssertTrue(child.inheritedQuestions.isEmpty)
        XCTAssertEqual(child.effectiveQuestions.map(\.prompt), ["Company specific"])
    }

    func testInheritanceAndMasterDeletionSurviveStoreReopen() throws {
        let fileManager = FileManager.default
        let storeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseInheritancePersistence-\(UUID().uuidString)", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("Rehearse.store")
        defer { try? fileManager.removeItem(at: storeDirectory) }

        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(
            "InheritancePersistence",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        let rootID: UUID
        let middleID: UUID
        let leafID: UUID
        do {
            let initialContainer = try ModelContainer(for: schema, configurations: [configuration])
            let initialContext = initialContainer.mainContext
            let root = Interview(company: "Core", role: "Master")
            let middle = Interview(company: "Platform", role: "Shared")
            let leaf = Interview(company: "Acme", role: "Designer")
            middle.parentInterview = root
            leaf.parentInterview = middle
            [root, middle, leaf].forEach(initialContext.insert)
            [
                Question(prompt: "Root", interview: root),
                Question(prompt: "Middle", interview: middle),
                Question(prompt: "Leaf", interview: leaf)
            ].forEach(initialContext.insert)
            try initialContext.save()
            rootID = root.id
            middleID = middle.id
            leafID = leaf.id
        }

        do {
            let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
            let reopenedContext = reopenedContainer.mainContext
            let interviews = try reopenedContext.fetch(FetchDescriptor<Interview>())
            let root = try XCTUnwrap(interviews.first { $0.id == rootID })
            let middle = try XCTUnwrap(interviews.first { $0.id == middleID })
            let leaf = try XCTUnwrap(interviews.first { $0.id == leafID })

            XCTAssertEqual(middle.parentInterview?.id, root.id)
            XCTAssertEqual(leaf.parentInterview?.id, middle.id)
            XCTAssertEqual(leaf.effectiveQuestions.map(\.prompt), ["Root", "Middle", "Leaf"])

            reopenedContext.delete(root)
            try reopenedContext.save()
        }

        let finalContainer = try ModelContainer(for: schema, configurations: [configuration])
        let finalContext = finalContainer.mainContext
        let finalInterviews = try finalContext.fetch(FetchDescriptor<Interview>())
        let finalMiddle = try XCTUnwrap(finalInterviews.first { $0.id == middleID })
        let finalLeaf = try XCTUnwrap(finalInterviews.first { $0.id == leafID })
        XCTAssertNil(finalMiddle.parentInterview)
        XCTAssertEqual(finalLeaf.parentInterview?.id, middleID)
        XCTAssertEqual(finalLeaf.effectiveQuestions.map(\.prompt), ["Middle", "Leaf"])
    }

    func testQuestionOverrideSurvivesStoreReopenAndKeepsSourceIsolated() throws {
        let fileManager = FileManager.default
        let storeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseOverridePersistence-\(UUID().uuidString)", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("Rehearse.store")
        defer { try? fileManager.removeItem(at: storeDirectory) }

        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(
            "OverridePersistence",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        let masterID: UUID
        let childID: UUID
        let siblingID: UUID
        let sourceID: UUID
        let untouchedID: UUID
        let overrideID: UUID

        do {
            let initialContainer = try ModelContainer(for: schema, configurations: [configuration])
            let initialContext = initialContainer.mainContext
            let master = Interview(company: "Core", role: "Master")
            let child = Interview(company: "Acme", role: "Designer")
            let sibling = Interview(company: "Beta", role: "Designer")
            child.parentInterview = master
            sibling.parentInterview = master
            let source = Question(
                prompt: "Shared prompt",
                answerFormat: .plain,
                plainAnswer: "Shared answer",
                sortIndex: 0,
                interview: master
            )
            let untouched = Question(
                prompt: "Still inherited",
                plainAnswer: "Original",
                sortIndex: 1,
                interview: master
            )
            [master, child, sibling].forEach(initialContext.insert)
            [source, untouched].forEach(initialContext.insert)
            try initialContext.save()

            let override = child.materializeQuestionOverride(for: source)
            override.prompt = "Acme prompt"
            override.plainAnswer = "Acme answer"
            initialContext.insert(override)
            try initialContext.save()

            masterID = master.id
            childID = child.id
            siblingID = sibling.id
            sourceID = source.id
            untouchedID = untouched.id
            overrideID = override.id
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: [configuration])
        let reopenedContext = reopenedContainer.mainContext
        let interviews = try reopenedContext.fetch(FetchDescriptor<Interview>())
        let questions = try reopenedContext.fetch(FetchDescriptor<Question>())
        let master = try XCTUnwrap(interviews.first { $0.id == masterID })
        let child = try XCTUnwrap(interviews.first { $0.id == childID })
        let sibling = try XCTUnwrap(interviews.first { $0.id == siblingID })
        let source = try XCTUnwrap(questions.first { $0.id == sourceID })
        let untouched = try XCTUnwrap(questions.first { $0.id == untouchedID })
        let override = try XCTUnwrap(questions.first { $0.id == overrideID })

        XCTAssertEqual(override.overrideSourceQuestionID, source.id)
        XCTAssertEqual(override.interview?.id, child.id)
        XCTAssertEqual(child.effectiveQuestions.map(\.id), [override.id, untouched.id])
        XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [override.id, untouched.id])
        XCTAssertTrue(child.inheritedSourceQuestion(for: override) === source)
        XCTAssertEqual(master.effectiveQuestions.map(\.id), [source.id, untouched.id])
        XCTAssertEqual(sibling.effectiveQuestions.map(\.id), [source.id, untouched.id])

        source.prompt = "Updated shared prompt"
        untouched.plainAnswer = "Updated everywhere"
        try reopenedContext.save()

        XCTAssertEqual(override.prompt, "Acme prompt")
        XCTAssertEqual(override.plainAnswer, "Acme answer")
        XCTAssertEqual(child.effectiveQuestions.last?.plainAnswer, "Updated everywhere")
        XCTAssertEqual(sibling.effectiveQuestions.first?.prompt, "Updated shared prompt")
    }

    func testCycleHelpersAndTraversalAreDefensive() throws {
        let root = Interview(company: "Core", role: "Master")
        let middle = Interview(company: "Platform", role: "Shared")
        middle.parentInterview = root
        let leaf = Interview(company: "Acme", role: "Designer")
        leaf.parentInterview = middle
        let unrelated = Interview(company: "Other", role: "Role")

        XCTAssertTrue(root.wouldCreateInheritanceCycle(with: leaf))
        XCTAssertTrue(root.wouldCreateInheritanceCycle(with: root))
        XCTAssertFalse(root.wouldCreateInheritanceCycle(with: unrelated))
        XCTAssertTrue(root.canInherit(from: nil))
        XCTAssertFalse(root.canInherit(from: leaf))

        let rootQuestion = Question(prompt: "Root", interview: root)
        let middleQuestion = Question(prompt: "Middle", interview: middle)
        let leafQuestion = Question(prompt: "Leaf", interview: leaf)
        [root, middle, leaf].forEach(context.insert)
        [rootQuestion, middleQuestion, leafQuestion].forEach(context.insert)
        try context.save()

        root.parentInterview = leaf // Simulate malformed persisted data without saving it.

        XCTAssertEqual(leaf.inheritedQuestions.map(\.prompt), ["Root", "Middle"])
        XCTAssertEqual(leaf.effectiveQuestions.map(\.prompt), ["Root", "Middle", "Leaf"])
        XCTAssertEqual(Set(leaf.effectiveQuestions.map(\.id)).count, 3)
        XCTAssertFalse(root.wouldCreateInheritanceCycle(with: unrelated))
    }

    func testDeletingMasterNullifiesChildRelationshipAndPreservesChildContent() throws {
        let master = Interview(company: "Core", role: "Master")
        let company = Interview(company: "Acme", role: "Designer")
        company.parentInterview = master
        let masterQuestion = Question(prompt: "Common", interview: master)
        let companyQuestion = Question(prompt: "Specific", interview: company)
        let masterAttempt = PracticeAttempt(rating: .good, question: masterQuestion)
        let companyAttempt = PracticeAttempt(rating: .confident, question: companyQuestion)
        [master, company].forEach(context.insert)
        [masterQuestion, companyQuestion].forEach(context.insert)
        [masterAttempt, companyAttempt].forEach(context.insert)
        try context.save()

        context.delete(master)
        XCTAssertEqual(company.effectiveQuestions.map(\.prompt), ["Specific"])
        try context.save()

        let survivingInterviews = try context.fetch(FetchDescriptor<Interview>())
        let survivingCompany = try XCTUnwrap(survivingInterviews.first(where: { $0.id == company.id }))
        XCTAssertNil(survivingCompany.parentInterview)
        XCTAssertEqual(survivingCompany.sortedQuestions.map(\.prompt), ["Specific"])
        XCTAssertEqual(survivingCompany.effectiveQuestions.map(\.prompt), ["Specific"])
        XCTAssertFalse(survivingInterviews.contains(where: { $0.id == master.id }))

        let survivingQuestions = try context.fetch(FetchDescriptor<Question>())
        XCTAssertEqual(survivingQuestions.map(\.id), [companyQuestion.id])
        XCTAssertEqual(survivingQuestions.first?.practiceAttempts.map(\.id), [companyAttempt.id])

        let survivingAttempts = try context.fetch(FetchDescriptor<PracticeAttempt>())
        XCTAssertEqual(survivingAttempts.map(\.id), [companyAttempt.id])
        XCTAssertFalse(survivingAttempts.contains(where: { $0.id == masterAttempt.id }))
    }

    func testMaterializedOverrideCopiesEditableMetadataWithoutPracticeHistory() throws {
        let sourceCreatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let sourceUpdatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let master = Interview(company: "Core", role: "Master")
        let child = Interview(company: "Acme", role: "Designer")
        let sibling = Interview(company: "Beta", role: "Designer")
        child.parentInterview = master
        sibling.parentInterview = master

        let source = Question(
            prompt: "Tell me about a launch",
            category: .technical,
            talkingPoints: ["Scope", "Tradeoffs"],
            answerFormat: .plain,
            situation: "Legacy situation",
            task: "Own delivery",
            action: "Aligned the team",
            result: "Shipped early",
            plainAnswer: "A complete prepared answer",
            tags: ["leadership", "launch"],
            isFavorite: true,
            confidence: .confident,
            sortIndex: 3,
            createdAt: sourceCreatedAt,
            updatedAt: sourceUpdatedAt,
            interview: master
        )
        let untouched = Question(
            prompt: "Why this role?",
            plainAnswer: "Shared answer",
            sortIndex: 4,
            interview: master
        )
        let childOnly = Question(prompt: "Acme-specific", sortIndex: 0, interview: child)
        let sourceAttempt = PracticeAttempt(
            rating: .confident,
            practicedAt: Date(timeIntervalSinceReferenceDate: 300),
            question: source
        )
        [master, child, sibling].forEach(context.insert)
        [source, untouched, childOnly].forEach(context.insert)
        context.insert(sourceAttempt)
        try context.save()

        let override = child.materializeQuestionOverride(for: source)
        XCTAssertTrue(child.materializeQuestionOverride(for: source) === override)
        context.insert(override)
        try context.save()

        XCTAssertNotEqual(override.id, source.id)
        XCTAssertEqual(override.overrideSourceQuestionID, source.id)
        XCTAssertEqual(override.interview?.id, child.id)
        XCTAssertEqual(override.prompt, source.prompt)
        XCTAssertEqual(override.categoryRaw, source.categoryRaw)
        XCTAssertEqual(override.talkingPoints, source.talkingPoints)
        XCTAssertEqual(override.answerFormatRaw, source.answerFormatRaw)
        XCTAssertEqual(override.situation, source.situation)
        XCTAssertEqual(override.task, source.task)
        XCTAssertEqual(override.action, source.action)
        XCTAssertEqual(override.result, source.result)
        XCTAssertEqual(override.plainAnswer, source.plainAnswer)
        XCTAssertEqual(override.tags, source.tags)
        XCTAssertEqual(override.isFavorite, source.isFavorite)
        XCTAssertEqual(override.confidenceRaw, source.confidenceRaw)
        XCTAssertEqual(override.sortIndex, source.sortIndex)
        XCTAssertGreaterThan(override.createdAt, sourceCreatedAt)
        XCTAssertGreaterThan(override.updatedAt, sourceUpdatedAt)
        XCTAssertTrue(override.practiceAttempts.isEmpty)
        XCTAssertEqual(source.practiceAttempts.map(\.id), [sourceAttempt.id])

        XCTAssertTrue(child.materializeQuestionOverride(for: source) === override)
        XCTAssertTrue(child.materializeQuestionOverride(for: override) === override)
        XCTAssertEqual(child.effectiveQuestions.map(\.id), [override.id, untouched.id, childOnly.id])
        XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [override.id, untouched.id])
        XCTAssertEqual(child.effectiveLocalQuestions.map(\.id), [childOnly.id])
        XCTAssertTrue(child.inheritedSourceQuestion(for: override) === source)
        XCTAssertEqual(child.inheritedSource(for: override)?.id, master.id)
        XCTAssertNil(child.inheritedSourceQuestion(for: childOnly))

        override.prompt = "Acme launch"
        override.plainAnswer = "Acme-only answer"
        untouched.plainAnswer = "Updated in master"

        XCTAssertEqual(master.effectiveQuestions.map(\.prompt), [source.prompt, untouched.prompt])
        XCTAssertEqual(sibling.effectiveQuestions.map(\.id), [source.id, untouched.id])
        XCTAssertEqual(sibling.effectiveQuestions.first?.plainAnswer, source.plainAnswer)
        XCTAssertEqual(child.effectiveQuestions.first?.plainAnswer, "Acme-only answer")
        XCTAssertEqual(child.effectiveQuestions[1].plainAnswer, "Updated in master")
    }

    func testNearestOverrideWinsInPlaceAcrossMultipleLevels() throws {
        let root = Interview(company: "Core", role: "Master")
        let middle = Interview(company: "Platform", role: "Shared")
        let leaf = Interview(company: "Acme", role: "Designer")
        middle.parentInterview = root
        leaf.parentInterview = middle

        let rootFirst = Question(prompt: "Root first", sortIndex: 0, interview: root)
        let rootSecond = Question(prompt: "Root second", sortIndex: 1, interview: root)
        let middleOnly = Question(prompt: "Middle only", sortIndex: 0, interview: middle)
        let leafOnly = Question(prompt: "Leaf only", sortIndex: 0, interview: leaf)
        [root, middle, leaf].forEach(context.insert)
        [rootFirst, rootSecond, middleOnly, leafOnly].forEach(context.insert)
        try context.save()

        let middleSecond = middle.materializeQuestionOverride(for: rootSecond)
        middleSecond.prompt = "Middle second"
        context.insert(middleSecond)
        try context.save()

        let leafFirst = leaf.materializeQuestionOverride(for: rootFirst)
        leafFirst.prompt = "Leaf first"
        context.insert(leafFirst)
        let leafSecond = leaf.materializeQuestionOverride(for: middleSecond)
        leafSecond.prompt = "Leaf second"
        context.insert(leafSecond)
        try context.save()

        XCTAssertEqual(middleSecond.overrideSourceQuestionID, rootSecond.id)
        XCTAssertEqual(leafFirst.overrideSourceQuestionID, rootFirst.id)
        XCTAssertEqual(leafSecond.overrideSourceQuestionID, rootSecond.id)
        XCTAssertEqual(
            leaf.effectiveQuestions.map(\.prompt),
            ["Leaf first", "Leaf second", "Middle only", "Leaf only"]
        )
        XCTAssertEqual(Set(leaf.effectiveQuestions.map(\.id)).count, 4)
        XCTAssertEqual(
            leaf.effectiveInheritedQuestions.map(\.id),
            [leafFirst.id, leafSecond.id, middleOnly.id]
        )
        XCTAssertEqual(leaf.effectiveLocalQuestions.map(\.id), [leafOnly.id])
        XCTAssertTrue(leaf.inheritedSourceQuestion(for: leafFirst) === rootFirst)
        XCTAssertTrue(leaf.inheritedSourceQuestion(for: leafSecond) === middleSecond)
        XCTAssertTrue(leaf.inheritedSourceQuestion(for: middleOnly) === middleOnly)
        XCTAssertTrue(leaf.materializeQuestionOverride(for: rootSecond) === leafSecond)
        XCTAssertEqual(middle.effectiveQuestions.map(\.prompt), ["Root first", "Middle second", "Middle only"])
        XCTAssertEqual(root.effectiveQuestions.map(\.prompt), ["Root first", "Root second"])
    }

    func testDeletingIntermediateOverrideKeepsDescendantOnCanonicalLineage() throws {
        let root = Interview(company: "Core", role: "Master")
        let middle = Interview(company: "Platform", role: "Shared")
        let leaf = Interview(company: "Acme", role: "Designer")
        middle.parentInterview = root
        leaf.parentInterview = middle
        let rootQuestion = Question(prompt: "Root", sortIndex: 0, interview: root)
        let untouched = Question(prompt: "Untouched", sortIndex: 1, interview: root)
        [root, middle, leaf].forEach(context.insert)
        [rootQuestion, untouched].forEach(context.insert)
        try context.save()

        let middleOverride = middle.materializeQuestionOverride(for: rootQuestion)
        middleOverride.prompt = "Middle"
        context.insert(middleOverride)
        try context.save()
        let leafOverride = leaf.materializeQuestionOverride(for: middleOverride)
        leafOverride.prompt = "Leaf"
        context.insert(leafOverride)
        try context.save()

        XCTAssertEqual(leafOverride.overrideSourceQuestionID, rootQuestion.id)
        XCTAssertEqual(leaf.effectiveQuestions.map(\.prompt), ["Leaf", "Untouched"])

        context.delete(middleOverride)
        try context.save()

        XCTAssertEqual(leaf.effectiveQuestions.map(\.prompt), ["Leaf", "Untouched"])
        XCTAssertEqual(Set(leaf.effectiveQuestions.map(\.id)).count, 2)
        XCTAssertTrue(leaf.inheritedSourceQuestion(for: leafOverride) === rootQuestion)
        untouched.prompt = "Still live"
        XCTAssertEqual(leaf.effectiveQuestions.last?.prompt, "Still live")
    }

    func testOverrideBecomesLocalWhenDetachedOrItsSourceIsDeleted() throws {
        let master = Interview(company: "Core", role: "Master")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = master
        let source = Question(prompt: "Shared", sortIndex: 0, interview: master)
        let local = Question(prompt: "Local", sortIndex: 1, interview: child)
        [master, child].forEach(context.insert)
        [source, local].forEach(context.insert)
        try context.save()

        let override = child.materializeQuestionOverride(for: source)
        override.prompt = "Customized"
        context.insert(override)
        let overrideAttempt = PracticeAttempt(rating: .good, question: override)
        context.insert(overrideAttempt)
        try context.save()

        child.parentInterview = nil
        try context.save()

        XCTAssertTrue(child.effectiveInheritedQuestions.isEmpty)
        XCTAssertEqual(child.effectiveLocalQuestions.map(\.prompt), ["Customized", "Local"])
        XCTAssertEqual(child.effectiveQuestions.map(\.prompt), ["Customized", "Local"])
        XCTAssertNil(child.inheritedSourceQuestion(for: override))
        XCTAssertEqual(override.overrideSourceQuestionID, source.id)
        XCTAssertTrue(child.materializeQuestionOverride(for: source) === source)
        XCTAssertEqual(Set(child.questions.map(\.id)), Set([override.id, local.id]))

        child.parentInterview = master
        try context.save()
        XCTAssertEqual(child.effectiveQuestions.map(\.prompt), ["Customized", "Local"])
        XCTAssertTrue(child.materializeQuestionOverride(for: source) === override)

        context.delete(source)
        try context.save()

        XCTAssertTrue(child.effectiveInheritedQuestions.isEmpty)
        XCTAssertEqual(child.effectiveLocalQuestions.map(\.prompt), ["Customized", "Local"])
        XCTAssertEqual(override.practiceAttempts.map(\.id), [overrideAttempt.id])
        XCTAssertEqual(override.overrideSourceQuestionID, source.id)
    }

    func testOutOfOrderDirectOverrideChainResolvesToOneInheritedSlot() throws {
        let root = Interview(company: "Core", role: "Master")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = root
        let source = Question(prompt: "Root", sortIndex: 0, interview: root)
        [root, child].forEach(context.insert)
        context.insert(source)
        try context.save()

        // Simulate older direct-link data whose most-derived override sorts
        // before the intermediate record it names. Resolution must follow the
        // lineage graph, rather than depending on relationship array order.
        let intermediate = Question(
            prompt: "Intermediate",
            sortIndex: 1,
            overrideSourceQuestionID: source.id,
            interview: child
        )
        let mostDerived = Question(
            prompt: "Most derived",
            sortIndex: 0,
            overrideSourceQuestionID: intermediate.id,
            interview: child
        )
        [intermediate, mostDerived].forEach(context.insert)
        try context.save()

        XCTAssertEqual(child.effectiveQuestions.map(\.id), [mostDerived.id])
        XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [mostDerived.id])
        XCTAssertTrue(child.inheritedSourceQuestion(for: mostDerived) === source)
        XCTAssertTrue(child.materializeQuestionOverride(for: source) === mostDerived)
        XCTAssertEqual(child.effectiveQuestions.map(\.id), [mostDerived.id])
    }

    func testMaterializingAnyDuplicateLineageMemberReturnsEffectiveOverride() throws {
        let root = Interview(company: "Core", role: "Master")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = root
        let source = Question(prompt: "Root", interview: root)
        let firstOverride = Question(
            prompt: "First copy",
            sortIndex: 0,
            overrideSourceQuestionID: source.id,
            interview: child
        )
        let effectiveOverride = Question(
            prompt: "Effective copy",
            sortIndex: 1,
            overrideSourceQuestionID: source.id,
            interview: child
        )
        [root, child].forEach(context.insert)
        [source, firstOverride, effectiveOverride].forEach(context.insert)
        try context.save()

        XCTAssertEqual(child.effectiveQuestions.map(\.id), [effectiveOverride.id])
        XCTAssertTrue(child.materializeQuestionOverride(for: source) === effectiveOverride)
        XCTAssertTrue(child.materializeQuestionOverride(for: firstOverride) === effectiveOverride)
        XCTAssertTrue(child.materializeQuestionOverride(for: effectiveOverride) === effectiveOverride)
    }

    func testEditingLegacyDirectOverrideCanonicalizesItBeforeReparenting() throws {
        let root = Interview(company: "Core", role: "Master")
        let middle = Interview(company: "Platform", role: "Shared")
        let leaf = Interview(company: "Acme", role: "Designer")
        middle.parentInterview = root
        leaf.parentInterview = middle
        let source = Question(prompt: "Root", interview: root)
        [root, middle, leaf].forEach(context.insert)
        context.insert(source)
        try context.save()

        let middleOverride = middle.materializeQuestionOverride(for: source)
        context.insert(middleOverride)
        try context.save()
        let legacyDirectOverride = Question(
            prompt: "Leaf",
            overrideSourceQuestionID: middleOverride.id,
            interview: leaf
        )
        context.insert(legacyDirectOverride)
        try context.save()

        XCTAssertEqual(legacyDirectOverride.overrideSourceQuestionID, middleOverride.id)
        XCTAssertTrue(leaf.materializeQuestionOverride(for: legacyDirectOverride) === legacyDirectOverride)
        XCTAssertEqual(legacyDirectOverride.overrideSourceQuestionID, source.id)

        leaf.parentInterview = root
        try context.save()

        XCTAssertEqual(leaf.effectiveQuestions.map(\.id), [legacyDirectOverride.id])
        XCTAssertTrue(leaf.inheritedSourceQuestion(for: legacyDirectOverride) === source)
    }

    func testDeletingChildOverrideRevealsLiveSourceAgain() throws {
        let root = Interview(company: "Core", role: "Master")
        let child = Interview(company: "Acme", role: "Designer")
        child.parentInterview = root
        let source = Question(prompt: "Root", plainAnswer: "Shared", interview: root)
        [root, child].forEach(context.insert)
        context.insert(source)
        try context.save()

        let override = child.materializeQuestionOverride(for: source)
        override.plainAnswer = "Child-only"
        context.insert(override)
        try context.save()
        XCTAssertEqual(child.effectiveQuestions.map(\.id), [override.id])

        context.delete(override)
        XCTAssertEqual(child.effectiveQuestions.map(\.id), [source.id])
        try context.save()

        XCTAssertEqual(child.effectiveQuestions.map(\.id), [source.id])
        source.plainAnswer = "Updated shared"
        XCTAssertEqual(child.effectiveQuestions.first?.plainAnswer, "Updated shared")
    }

    func testInvalidOverrideSourceAndQuestionCyclesStayFiniteAndDeterministic() throws {
        let interview = Interview(company: "Acme", role: "Designer")
        let missingSource = Question(
            prompt: "Missing source",
            sortIndex: 0,
            overrideSourceQuestionID: UUID(),
            interview: interview
        )
        let firstCycleMember = Question(prompt: "Cycle one", sortIndex: 1, interview: interview)
        let secondCycleMember = Question(prompt: "Cycle two", sortIndex: 2, interview: interview)
        firstCycleMember.overrideSourceQuestionID = secondCycleMember.id
        secondCycleMember.overrideSourceQuestionID = firstCycleMember.id
        context.insert(interview)
        [missingSource, firstCycleMember, secondCycleMember].forEach(context.insert)
        try context.save()

        XCTAssertEqual(
            interview.effectiveQuestions.map(\.id),
            [missingSource.id, secondCycleMember.id]
        )
        XCTAssertEqual(Set(interview.effectiveQuestions.map(\.id)).count, 2)
        XCTAssertTrue(
            interview.materializeQuestionOverride(for: firstCycleMember) === secondCycleMember
        )
    }
}
