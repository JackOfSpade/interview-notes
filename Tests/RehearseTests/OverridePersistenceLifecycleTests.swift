import Foundation
import XCTest
import SwiftData
@testable import Rehearse

/// Disk-backed regression coverage for the persistence boundaries introduced
/// by child-owned question overrides. The file-private models at the bottom of
/// this file intentionally reproduce the immediately preceding store schema:
/// the entity names and relationships are unchanged, but `Question` has no
/// `overrideSourceQuestionID` attribute.
@MainActor
final class OverridePersistenceLifecycleTests: XCTestCase {
    func testCurrentSchemaMigratesStoreCreatedBeforeQuestionOverrides() throws {
        try withStore(named: "PreOverrideMigration") { storeURL in
            let legacyURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(DataController.legacyStoreFileName)
            let masterID: UUID
            let childID: UUID
            let questionID: UUID
            let attemptID: UUID

            do {
                let schema = Schema([
                    Interview.self,
                    Question.self,
                    PracticeAttempt.self
                ])
                let configuration = ModelConfiguration(
                    "LegacyPreOverride",
                    schema: schema,
                    url: legacyURL,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(
                    for: schema,
                    configurations: [configuration]
                )
                let context = container.mainContext
                let master = Interview(company: "Core", role: "Master")
                let child = Interview(company: "Acme", role: "Designer")
                child.parentInterview = master
                let question = Question(
                    prompt: "Shared legacy question",
                    plainAnswer: "Legacy answer",
                    interview: master
                )
                let attempt = PracticeAttempt(
                    ratingRaw: Confidence.good.rawValue,
                    practicedAt: Date(timeIntervalSinceReferenceDate: 123),
                    question: question
                )
                [master, child].forEach(context.insert)
                context.insert(question)
                context.insert(attempt)
                try context.save()

                masterID = master.id
                childID = child.id
                questionID = question.id
                attemptID = attempt.id
            }

            try DataController.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: storeURL
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

            let currentSchema = Schema([
                Rehearse.Interview.self,
                Rehearse.Question.self,
                Rehearse.PracticeAttempt.self
            ])
            let currentConfiguration = ModelConfiguration(
                "CurrentAfterLegacy",
                schema: currentSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )

            let overrideID: UUID
            do {
                let container = try ModelContainer(
                    for: currentSchema,
                    configurations: [currentConfiguration]
                )
                let context = container.mainContext
                let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
                let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
                let attempts = try context.fetch(FetchDescriptor<Rehearse.PracticeAttempt>())
                let master = try XCTUnwrap(interviews.first { $0.id == masterID })
                let child = try XCTUnwrap(interviews.first { $0.id == childID })
                let source = try XCTUnwrap(questions.first { $0.id == questionID })

                XCTAssertEqual(child.parentInterview?.id, master.id)
                XCTAssertEqual(child.effectiveQuestions.map(\.id), [source.id])
                XCTAssertNil(source.overrideSourceQuestionID)
                XCTAssertEqual(attempts.map(\.id), [attemptID])
                XCTAssertEqual(source.practiceAttempts.map(\.id), [attemptID])

                let override = child.materializeQuestionOverride(for: source)
                override.prompt = "Child-only migrated edit"
                context.insert(override)
                try context.save()
                overrideID = override.id
            }

            let reopened = try ModelContainer(
                for: currentSchema,
                configurations: [currentConfiguration]
            )
            let context = reopened.mainContext
            let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
            let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
            let child = try XCTUnwrap(interviews.first { $0.id == childID })
            let source = try XCTUnwrap(questions.first { $0.id == questionID })
            let override = try XCTUnwrap(questions.first { $0.id == overrideID })

            XCTAssertEqual(override.overrideSourceQuestionID, source.id)
            XCTAssertEqual(child.effectiveQuestions.map(\.id), [override.id])
            XCTAssertEqual(source.prompt, "Shared legacy question")
            XCTAssertEqual(override.prompt, "Child-only migrated edit")
        }
    }

    func testDeletingSourceQuestionAfterReopenKeepsOverrideAndItsAttempt() throws {
        try withCurrentStore(named: "SourceDeletion") { schema, configuration in
            let masterID: UUID
            let childID: UUID
            let sourceID: UUID
            let sourceAttemptID: UUID
            let overrideID: UUID
            let overrideAttemptID: UUID

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let master = Rehearse.Interview(company: "Core", role: "Master")
                let child = Rehearse.Interview(company: "Acme", role: "Designer")
                child.parentInterview = master
                let source = Rehearse.Question(prompt: "Shared", interview: master)
                let sourceAttempt = Rehearse.PracticeAttempt(rating: .good, question: source)
                [master, child].forEach(context.insert)
                context.insert(source)
                context.insert(sourceAttempt)
                try context.save()

                let override = child.materializeQuestionOverride(for: source)
                override.prompt = "Customized"
                context.insert(override)
                let overrideAttempt = Rehearse.PracticeAttempt(
                    rating: .confident,
                    question: override
                )
                context.insert(overrideAttempt)
                try context.save()

                masterID = master.id
                childID = child.id
                sourceID = source.id
                sourceAttemptID = sourceAttempt.id
                overrideID = override.id
                overrideAttemptID = overrideAttempt.id
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let source = try XCTUnwrap(
                    try context.fetch(FetchDescriptor<Rehearse.Question>())
                        .first { $0.id == sourceID }
                )
                context.delete(source)
                try context.save()
            }

            let reopened = try ModelContainer(for: schema, configurations: [configuration])
            let context = reopened.mainContext
            let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
            let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
            let attempts = try context.fetch(FetchDescriptor<Rehearse.PracticeAttempt>())
            let master = try XCTUnwrap(interviews.first { $0.id == masterID })
            let child = try XCTUnwrap(interviews.first { $0.id == childID })
            let override = try XCTUnwrap(questions.first { $0.id == overrideID })

            XCTAssertTrue(master.questions.isEmpty)
            XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [])
            XCTAssertEqual(child.effectiveLocalQuestions.map(\.id), [override.id])
            XCTAssertEqual(override.overrideSourceQuestionID, sourceID)
            XCTAssertEqual(override.practiceAttempts.map(\.id), [overrideAttemptID])
            XCTAssertFalse(attempts.contains { $0.id == sourceAttemptID })
            XCTAssertEqual(attempts.map(\.id), [overrideAttemptID])
        }
    }

    func testDeletingParentInterviewAfterReopenKeepsChildOverrideAndItsAttempt() throws {
        try withCurrentStore(named: "ParentDeletion") { schema, configuration in
            let masterID: UUID
            let childID: UUID
            let sourceID: UUID
            let sourceAttemptID: UUID
            let overrideID: UUID
            let overrideAttemptID: UUID

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let master = Rehearse.Interview(company: "Core", role: "Master")
                let child = Rehearse.Interview(company: "Acme", role: "Designer")
                child.parentInterview = master
                let source = Rehearse.Question(prompt: "Shared", interview: master)
                let sourceAttempt = Rehearse.PracticeAttempt(rating: .again, question: source)
                [master, child].forEach(context.insert)
                context.insert(source)
                context.insert(sourceAttempt)
                try context.save()

                let override = child.materializeQuestionOverride(for: source)
                override.prompt = "Child copy"
                context.insert(override)
                let overrideAttempt = Rehearse.PracticeAttempt(
                    rating: .confident,
                    question: override
                )
                context.insert(overrideAttempt)
                try context.save()

                masterID = master.id
                childID = child.id
                sourceID = source.id
                sourceAttemptID = sourceAttempt.id
                overrideID = override.id
                overrideAttemptID = overrideAttempt.id
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let master = try XCTUnwrap(
                    try context.fetch(FetchDescriptor<Rehearse.Interview>())
                        .first { $0.id == masterID }
                )
                context.delete(master)
                try context.save()
            }

            let reopened = try ModelContainer(for: schema, configurations: [configuration])
            let context = reopened.mainContext
            let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
            let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
            let attempts = try context.fetch(FetchDescriptor<Rehearse.PracticeAttempt>())
            let child = try XCTUnwrap(interviews.first { $0.id == childID })
            let override = try XCTUnwrap(questions.first { $0.id == overrideID })

            XCTAssertFalse(interviews.contains { $0.id == masterID })
            XCTAssertNil(child.parentInterview)
            XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [])
            XCTAssertEqual(child.effectiveLocalQuestions.map(\.id), [override.id])
            XCTAssertEqual(override.overrideSourceQuestionID, sourceID)
            XCTAssertEqual(override.practiceAttempts.map(\.id), [overrideAttemptID])
            XCTAssertFalse(questions.contains { $0.id == sourceID })
            XCTAssertFalse(attempts.contains { $0.id == sourceAttemptID })
            XCTAssertEqual(attempts.map(\.id), [overrideAttemptID])
        }
    }

    func testDeletingIntermediateInterviewAfterReopenPreservesLeafOverrideAndAttempt() throws {
        try withCurrentStore(named: "IntermediateDeletion") { schema, configuration in
            let rootID: UUID
            let middleID: UUID
            let leafID: UUID
            let rootQuestionID: UUID
            let middleOverrideID: UUID
            let middleAttemptID: UUID
            let leafOverrideID: UUID
            let leafAttemptID: UUID

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let root = Rehearse.Interview(company: "Core", role: "Master")
                let middle = Rehearse.Interview(company: "Platform", role: "Shared")
                let leaf = Rehearse.Interview(company: "Acme", role: "Designer")
                middle.parentInterview = root
                leaf.parentInterview = middle
                let rootQuestion = Rehearse.Question(prompt: "Root", interview: root)
                [root, middle, leaf].forEach(context.insert)
                context.insert(rootQuestion)
                try context.save()

                let middleOverride = middle.materializeQuestionOverride(for: rootQuestion)
                middleOverride.prompt = "Middle"
                context.insert(middleOverride)
                let middleAttempt = Rehearse.PracticeAttempt(rating: .good, question: middleOverride)
                context.insert(middleAttempt)
                try context.save()

                let leafOverride = leaf.materializeQuestionOverride(for: middleOverride)
                leafOverride.prompt = "Leaf"
                context.insert(leafOverride)
                let leafAttempt = Rehearse.PracticeAttempt(rating: .confident, question: leafOverride)
                context.insert(leafAttempt)
                try context.save()

                rootID = root.id
                middleID = middle.id
                leafID = leaf.id
                rootQuestionID = rootQuestion.id
                middleOverrideID = middleOverride.id
                middleAttemptID = middleAttempt.id
                leafOverrideID = leafOverride.id
                leafAttemptID = leafAttempt.id
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let middle = try XCTUnwrap(
                    try context.fetch(FetchDescriptor<Rehearse.Interview>())
                        .first { $0.id == middleID }
                )
                context.delete(middle)
                try context.save()
            }

            let reopened = try ModelContainer(for: schema, configurations: [configuration])
            let context = reopened.mainContext
            let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
            let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
            let attempts = try context.fetch(FetchDescriptor<Rehearse.PracticeAttempt>())
            let root = try XCTUnwrap(interviews.first { $0.id == rootID })
            let leaf = try XCTUnwrap(interviews.first { $0.id == leafID })
            let rootQuestion = try XCTUnwrap(questions.first { $0.id == rootQuestionID })
            let leafOverride = try XCTUnwrap(questions.first { $0.id == leafOverrideID })

            XCTAssertNil(leaf.parentInterview)
            XCTAssertEqual(root.effectiveQuestions.map(\.id), [rootQuestion.id])
            XCTAssertEqual(leaf.effectiveInheritedQuestions.map(\.id), [])
            XCTAssertEqual(leaf.effectiveLocalQuestions.map(\.id), [leafOverride.id])
            XCTAssertEqual(leafOverride.overrideSourceQuestionID, rootQuestion.id)
            XCTAssertEqual(leafOverride.practiceAttempts.map(\.id), [leafAttemptID])
            XCTAssertFalse(questions.contains { $0.id == middleOverrideID })
            XCTAssertFalse(attempts.contains { $0.id == middleAttemptID })
            XCTAssertEqual(attempts.map(\.id), [leafAttemptID])
        }
    }

    func testDeletingChildOverrideAfterReopenRestoresSourceAndCascadesAttempt() throws {
        try withCurrentStore(named: "OverrideDeletion") { schema, configuration in
            let childID: UUID
            let sourceID: UUID
            let overrideID: UUID
            let overrideAttemptID: UUID

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let master = Rehearse.Interview(company: "Core", role: "Master")
                let child = Rehearse.Interview(company: "Acme", role: "Designer")
                child.parentInterview = master
                let source = Rehearse.Question(prompt: "Shared", interview: master)
                [master, child].forEach(context.insert)
                context.insert(source)
                try context.save()

                let override = child.materializeQuestionOverride(for: source)
                override.prompt = "Customized"
                context.insert(override)
                let attempt = Rehearse.PracticeAttempt(rating: .good, question: override)
                context.insert(attempt)
                try context.save()

                childID = child.id
                sourceID = source.id
                overrideID = override.id
                overrideAttemptID = attempt.id
            }

            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = container.mainContext
                let override = try XCTUnwrap(
                    try context.fetch(FetchDescriptor<Rehearse.Question>())
                        .first { $0.id == overrideID }
                )
                context.delete(override)
                try context.save()
            }

            let reopened = try ModelContainer(for: schema, configurations: [configuration])
            let context = reopened.mainContext
            let interviews = try context.fetch(FetchDescriptor<Rehearse.Interview>())
            let questions = try context.fetch(FetchDescriptor<Rehearse.Question>())
            let attempts = try context.fetch(FetchDescriptor<Rehearse.PracticeAttempt>())
            let child = try XCTUnwrap(interviews.first { $0.id == childID })
            let source = try XCTUnwrap(questions.first { $0.id == sourceID })

            XCTAssertEqual(child.effectiveQuestions.map(\.id), [source.id])
            XCTAssertEqual(child.effectiveInheritedQuestions.map(\.id), [source.id])
            XCTAssertFalse(questions.contains { $0.id == overrideID })
            XCTAssertFalse(attempts.contains { $0.id == overrideAttemptID })
        }
    }

    private func withCurrentStore(
        named name: String,
        _ body: (Schema, ModelConfiguration) throws -> Void
    ) throws {
        try withStore(named: name) { storeURL in
            let schema = Schema([
                Rehearse.Interview.self,
                Rehearse.Question.self,
                Rehearse.PracticeAttempt.self
            ])
            let configuration = ModelConfiguration(
                name,
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            try body(schema, configuration)
        }
    }

    private func withStore(named name: String, _ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Rehearse-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory.appendingPathComponent("Rehearse.store"))
    }
}

// MARK: - Pre-override fixture schema

@Model
private final class Interview {
    @Attribute(.unique) var id: UUID
    var company: String
    var role: String
    var interviewDate: Date?
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Question.interview)
    var questions: [Question] = []

    var parentInterview: Interview?

    @Relationship(deleteRule: .nullify, inverse: \Interview.parentInterview)
    var childInterviews: [Interview] = []

    init(
        id: UUID = UUID(),
        company: String,
        role: String,
        interviewDate: Date? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.company = company
        self.role = role
        self.interviewDate = interviewDate
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.questions = []
        self.parentInterview = nil
        self.childInterviews = []
    }
}

@Model
private final class Question {
    @Attribute(.unique) var id: UUID
    var prompt: String
    var categoryRaw: String
    var talkingPoints: [String]
    var answerFormatRaw: String
    var situation: String?
    var task: String?
    var action: String?
    var result: String?
    var plainAnswer: String?
    var tags: [String]
    var isFavorite: Bool
    var confidenceRaw: String
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date
    var interview: Interview?

    @Relationship(deleteRule: .cascade, inverse: \PracticeAttempt.question)
    var practiceAttempts: [PracticeAttempt] = []

    init(
        id: UUID = UUID(),
        prompt: String,
        categoryRaw: String = QuestionCategory.behavioral.rawValue,
        talkingPoints: [String] = [],
        answerFormatRaw: String = AnswerFormat.star.rawValue,
        situation: String? = nil,
        task: String? = nil,
        action: String? = nil,
        result: String? = nil,
        plainAnswer: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        confidenceRaw: String = Confidence.unrated.rawValue,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        interview: Interview? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.categoryRaw = categoryRaw
        self.talkingPoints = talkingPoints
        self.answerFormatRaw = answerFormatRaw
        self.situation = situation
        self.task = task
        self.action = action
        self.result = result
        self.plainAnswer = plainAnswer
        self.tags = tags
        self.isFavorite = isFavorite
        self.confidenceRaw = confidenceRaw
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.interview = interview
        self.practiceAttempts = []
    }
}

@Model
private final class PracticeAttempt {
    @Attribute(.unique) var id: UUID
    var ratingRaw: String
    var practicedAt: Date
    var question: Question?

    init(
        id: UUID = UUID(),
        ratingRaw: String,
        practicedAt: Date = Date(),
        question: Question? = nil
    ) {
        self.id = id
        self.ratingRaw = ratingRaw
        self.practicedAt = practicedAt
        self.question = question
    }
}
