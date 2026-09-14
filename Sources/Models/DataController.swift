import Foundation
import SwiftData
import CoreData
import Combine
import AppKit

@MainActor
public final class DataController: ObservableObject {
    public static let shared = DataController()
    static let storageDirectoryName = "com.rehearse.Rehearse"
    static let storeFileName = "Rehearse.store"
    static let legacyStoreFileName = "default.store"

    enum StorePreparationError: LocalizedError {
        case unexpectedDestination(URL)
        case invalidMigratedStore(URL)

        var errorDescription: String? {
            switch self {
            case .unexpectedDestination(let url):
                return "The existing destination is not a Rehearse data store: \(url.path)"
            case .invalidMigratedStore(let url):
                return "The migrated Rehearse data store could not be verified: \(url.path)"
            }
        }
    }

    public enum SaveStatus: Equatable {
        case idle
        case saving
        case saved(Date)
        case error(String)

        public var displayText: String {
            switch self {
            case .idle:
                return "Saved locally"
            case .saving:
                return "Saving…"
            case .saved(let date):
                let elapsed = abs(Date().timeIntervalSince(date))
                if elapsed < 60 {
                    return "Saved locally just now"
                }
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let rel = formatter.localizedString(for: date, relativeTo: Date())
                return "Saved locally \(rel)"
            case .error:
                return "Save failed"
            }
        }
    }

    public let container: ModelContainer
    public var context: ModelContext {
        container.mainContext
    }

    @Published public private(set) var saveStatus: SaveStatus = .idle
    private var saveCancellable: AnyCancellable?
    private let saveSubject = PassthroughSubject<Void, Never>()

    public init(inMemory: Bool = false) {
        do {
            let schema = Schema([
                Interview.self,
                Question.self,
                PracticeAttempt.self
            ])
            let configuration: ModelConfiguration
            if inMemory {
                configuration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            } else {
                let storeURL = try Self.preparePersistentStore()
                configuration = ModelConfiguration(
                    "Rehearse",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            }
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            AppSessionLogger.shared.log(
                Self.containerInitializationFailureLogMessage(for: error),
                level: .error
            )
            fatalError("Failed to initialize SwiftData container: \(error)")
        }

        setupDebounce()
        setupLifecycleObservers()
    }

    static func persistentStoreURL(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Keep startup diagnostics useful without serializing model values or
    /// other user-provided data into the session log.
    static func containerInitializationFailureLogMessage(for error: Error) -> String {
        "SwiftData container initialization failed (\(String(reflecting: type(of: error))))"
    }

    /// Moves future writes into an app-specific directory. Existing releases
    /// used SwiftData's generic root-level `default.store`; copy it with Core
    /// Data's store replacement API so its WAL contents are preserved. Once
    /// the namespaced copy has been verified, remove only a verified Rehearse
    /// legacy SQLite family so it cannot be reopened on a later launch.
    static func preparePersistentStore(fileManager: FileManager = .default) throws -> URL {
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destinationURL = persistentStoreURL(in: applicationSupportDirectory)
        let legacyURL = applicationSupportDirectory
            .appendingPathComponent(legacyStoreFileName, isDirectory: false)

        do {
            try migrateLegacyStoreIfNeeded(
                from: legacyURL,
                to: destinationURL,
                fileManager: fileManager
            )
            return destinationURL
        } catch {
            // If copying succeeded but cleanup was interrupted, the verified
            // destination is authoritative. Cleanup is retried on the next
            // launch. Before that point, a verified legacy store remains a safe
            // fallback. Never open an unknown generic `default.store`.
            if fileManager.fileExists(atPath: destinationURL.path),
               (try? isRehearseStore(at: destinationURL)) == true {
                AppSessionLogger.shared.log(
                    "Could not remove the legacy Rehearse data store: \(error)",
                    level: .warning
                )
                return destinationURL
            }
            if fileManager.fileExists(atPath: legacyURL.path),
               (try? isRehearseStore(at: legacyURL)) == true {
                AppSessionLogger.shared.log(
                    "Could not migrate the Rehearse data store: \(error)",
                    level: .warning
                )
                return legacyURL
            }
            throw error
        }
    }

    static func migrateLegacyStoreIfNeeded(
        from legacyURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        // Treat an accidental identical source and destination as a no-op;
        // cleanup must never be able to delete the active store.
        guard legacyURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            return
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard try isRehearseStore(at: destinationURL) else {
                throw StorePreparationError.unexpectedDestination(destinationURL)
            }
            try removeVerifiedLegacyStoreFamily(
                at: legacyURL,
                afterVerifying: destinationURL,
                fileManager: fileManager
            )
            return
        }

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return
        }

        // A readable generic store with different entities belongs to another
        // app. Leave it untouched and start a fresh namespaced Rehearse store.
        guard try isRehearseStore(at: legacyURL) else {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
        try coordinator.replacePersistentStore(
            at: destinationURL,
            withPersistentStoreFrom: legacyURL,
            type: .sqlite
        )

        guard fileManager.fileExists(atPath: destinationURL.path),
              try isRehearseStore(at: destinationURL) else {
            throw StorePreparationError.invalidMigratedStore(destinationURL)
        }

        try removeVerifiedLegacyStoreFamily(
            at: legacyURL,
            afterVerifying: destinationURL,
            fileManager: fileManager
        )
    }

    /// Deletes the primary SQLite file last. If removing a sidecar fails, the
    /// verified legacy primary remains available and a later launch can retry.
    /// A generic `default.store` is deliberately left untouched.
    private static func removeVerifiedLegacyStoreFamily(
        at legacyURL: URL,
        afterVerifying destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: legacyURL.path),
              (try? isRehearseStore(at: legacyURL)) == true else {
            return
        }
        guard fileManager.fileExists(atPath: destinationURL.path),
              try isRehearseStore(at: destinationURL) else {
            throw StorePreparationError.invalidMigratedStore(destinationURL)
        }

        let storeFamily = sqliteStoreFamilyURLs(for: legacyURL)
        for sidecarURL in storeFamily.dropFirst() where fileManager.fileExists(atPath: sidecarURL.path) {
            try fileManager.removeItem(at: sidecarURL)
        }
        try fileManager.removeItem(at: legacyURL)
    }

    private static func sqliteStoreFamilyURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: storeURL.path + "-shm", isDirectory: false)
        ]
    }

    private static func isRehearseStore(at url: URL) throws -> Bool {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: url
        )
        guard let hashes = metadata["NSStoreModelVersionHashes"] as? [String: Any] else {
            return false
        }

        let requiredEntities: Set<String> = ["Interview", "Question", "PracticeAttempt"]
        return requiredEntities.isSubset(of: Set(hashes.keys))
    }

    private func setupDebounce() {
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.performSave()
            }
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSave()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSave()
                // Keep the session log writable until the final save has
                // completed, including any save failure that needs recording.
                AppSessionLogger.shared.finish()
            }
        }
    }

    /// Request a debounced save (e.g. while user is typing in editor)
    public func scheduleSave() {
        saveStatus = .saving
        saveSubject.send(())
    }

    /// Immediate save (on focus change, navigation, app resign)
    public func flushSave() {
        performSave()
    }

    private func performSave() {
        guard context.hasChanges else {
            // A debounced request can arrive after an earlier flush has already
            // saved the context. It still represents a completed save cycle.
            saveStatus = .saved(Date())
            return
        }

        do {
            try context.save()
            saveStatus = .saved(Date())
        } catch {
            saveStatus = .error(error.localizedDescription)
            AppSessionLogger.shared.log(
                "SwiftData save failed (\(String(reflecting: type(of: error))))",
                level: .error
            )
        }
    }
}
