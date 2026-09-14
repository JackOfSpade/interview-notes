import XCTest
import SwiftData
import CoreData
@testable import Rehearse

@MainActor
final class DataControllerTests: XCTestCase {
    func testContainerInitializationFailureLogMessageExcludesErrorDetails() {
        let error = NSError(
            domain: "RehearseTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A private answer should not be logged"]
        )

        let message = DataController.containerInitializationFailureLogMessage(for: error)

        XCTAssertTrue(message.contains("NSError"))
        XCTAssertFalse(message.contains("private answer"))
    }

    func testDebouncedSaveAfterFlushMarksStatusSaved() async throws {
        let controller = DataController(inMemory: true)

        // A flush can consume the pending model changes before the debounce fires.
        controller.flushSave()
        guard case .saved = controller.saveStatus else {
            return XCTFail("An empty flush should report a completed save")
        }

        controller.scheduleSave()
        XCTAssertEqual(controller.saveStatus, .saving)

        try await Task.sleep(for: .milliseconds(650))

        guard case .saved = controller.saveStatus else {
            return XCTFail("The completed debounce should not leave the UI in saving state")
        }
    }

    func testDebouncedSaveCommitsPendingEditorChanges() async throws {
        let controller = DataController(inMemory: true)
        controller.context.insert(Interview(company: "Acme", role: "Design Lead"))
        XCTAssertTrue(controller.context.hasChanges)

        controller.scheduleSave()
        try await Task.sleep(for: .milliseconds(650))

        XCTAssertFalse(controller.context.hasChanges)
        guard case .saved = controller.saveStatus else {
            return XCTFail("A pending editor change should be committed by the debounce")
        }
    }

    func testPersistentStoreURLIsNamespaced() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        let url = DataController.persistentStoreURL(in: applicationSupport)

        XCTAssertEqual(
            url.path,
            "/tmp/Application Support/com.rehearse.Rehearse/Rehearse.store"
        )
    }

    func testLegacyStoreMigrationPreservesRecordsAndRemovesLegacyStoreFamily() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let legacyURL = root.appendingPathComponent(DataController.legacyStoreFileName)
        let destinationURL = DataController.persistentStoreURL(in: root)

        try createRehearseStore(
            at: legacyURL,
            company: "Acme",
            role: "Design Lead",
            questionPrompt: "Tell me about your best launch."
        )

        try DataController.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: sqliteStoreFamilyURLs(for: legacyURL)[1].path))
        XCTAssertFalse(fileManager.fileExists(atPath: sqliteStoreFamilyURLs(for: legacyURL)[2].path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationURL.path))

        let migratedConfiguration = ModelConfiguration(
            "MigratedRehearse",
            schema: schema,
            url: destinationURL,
            cloudKitDatabase: .none
        )
        let migratedContainer = try ModelContainer(for: schema, configurations: [migratedConfiguration])
        let interviews = try migratedContainer.mainContext.fetch(FetchDescriptor<Interview>())
        let questions = try migratedContainer.mainContext.fetch(FetchDescriptor<Question>())

        XCTAssertEqual(interviews.map(\.title), ["Acme — Design Lead"])
        XCTAssertEqual(questions.map(\.prompt), ["Tell me about your best launch."])
    }

    func testExistingVerifiedDestinationCleansUpVerifiedLegacyStoreFamily() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseLegacyCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let legacyURL = root.appendingPathComponent(DataController.legacyStoreFileName)
        let destinationURL = DataController.persistentStoreURL(in: root)
        try createRehearseStore(at: legacyURL, company: "Legacy", role: "Role")
        try createRehearseStore(at: destinationURL, company: "Destination", role: "Role")

        let legacyFamily = sqliteStoreFamilyURLs(for: legacyURL)
        try Data("stale WAL".utf8).write(to: legacyFamily[1])
        try Data("stale SHM".utf8).write(to: legacyFamily[2])

        try DataController.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        for url in legacyFamily {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path), "Expected legacy file to be removed: \(url.lastPathComponent)")
        }

        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration("Destination", schema: schema, url: destinationURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let interviews = try container.mainContext.fetch(FetchDescriptor<Interview>())
        XCTAssertEqual(interviews.map(\.title), ["Destination — Role"])
    }

    func testExistingVerifiedDestinationPreservesGenericLegacyStoreFamily() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseGenericLegacyTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let legacyURL = root.appendingPathComponent(DataController.legacyStoreFileName)
        let destinationURL = DataController.persistentStoreURL(in: root)
        try createGenericStore(at: legacyURL)
        try createRehearseStore(at: destinationURL, company: "Destination", role: "Role")

        let legacyFamily = sqliteStoreFamilyURLs(for: legacyURL)
        try Data("another app WAL".utf8).write(to: legacyFamily[1])
        try Data("another app SHM".utf8).write(to: legacyFamily[2])

        try DataController.migrateLegacyStoreIfNeeded(
            from: legacyURL,
            to: destinationURL,
            fileManager: fileManager
        )

        for url in legacyFamily {
            XCTAssertTrue(fileManager.fileExists(atPath: url.path), "Generic store file must remain: \(url.lastPathComponent)")
        }
    }

    func testLegacyMigrationRejectsAnIncompleteDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseInterruptedMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let legacyURL = root.appendingPathComponent(DataController.legacyStoreFileName)
        do {
            let configuration = ModelConfiguration(
                "LegacyRehearse",
                schema: schema,
                url: legacyURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: schema, configurations: [configuration])
            legacyContainer.mainContext.insert(Interview(company: "Safe", role: "Backup"))
            try legacyContainer.mainContext.save()
        }

        let destinationURL = DataController.persistentStoreURL(in: root)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let incompleteContents = Data("incomplete migration".utf8)
        try incompleteContents.write(to: destinationURL)

        XCTAssertThrowsError(
            try DataController.migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), incompleteContents)
        XCTAssertTrue(fileManager.fileExists(atPath: legacyURL.path))
    }

    private func createRehearseStore(
        at url: URL,
        company: String,
        role: String,
        questionPrompt: String? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let schema = Schema([Interview.self, Question.self, PracticeAttempt.self])
        let configuration = ModelConfiguration("RehearseTest", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let interview = Interview(company: company, role: role)
        container.mainContext.insert(interview)
        if let questionPrompt {
            container.mainContext.insert(Question(prompt: questionPrompt, interview: interview))
        }
        try container.mainContext.save()
    }

    private func createGenericStore(at url: URL) throws {
        let entity = NSEntityDescription()
        entity.name = "OtherAppRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url,
            options: nil
        )
    }

    private func sqliteStoreFamilyURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: storeURL.path + "-shm", isDirectory: false)
        ]
    }
}
