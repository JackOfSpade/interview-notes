import AppKit
import Foundation

/// A small, local log for the current launch of the app. The file is reset at
/// the start of each process so it remains useful for diagnosing the latest
/// session without accumulating indefinitely.
@MainActor
public final class AppSessionLogger: NSObject {
    public static let shared = AppSessionLogger()

    static let logDirectoryName = "com.rehearse.Rehearse"
    static let logFileName = "last-session.log"

    public enum Level: String {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    public private(set) var logFileURL: URL?

    private let dateFormatter: ISO8601DateFormatter
    private var fileHandle: FileHandle?
    private var hasFinished = false

    public convenience override init() {
        self.init(logDirectory: nil)
    }

    init(logDirectory: URL?, fileManager: FileManager = .default) {
        dateFormatter = ISO8601DateFormatter()
        super.init()

        do {
            let directory = try logDirectory ?? Self.defaultLogDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = Self.logFileURL(in: directory)
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            fileHandle = handle
            logFileURL = fileURL
            log("Session started")
        } catch {
            // Logging must never prevent the app from launching. Keep this
            // fallback visible to a developer when the log directory is not
            // writable.
            print("Could not start the session log: \(error.localizedDescription)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    public func log(_ message: String, level: Level = .info) {
        guard !hasFinished, let fileHandle else { return }

        let line = "\(dateFormatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        do {
            try fileHandle.write(contentsOf: Data(line.utf8))
        } catch {
            print("Could not write to the session log: \(error.localizedDescription)")
        }
    }

    public func finish() {
        guard !hasFinished else { return }
        log("Session ended")
        hasFinished = true
        if let fileHandle {
            // The final line is useful precisely when investigating a quit or
            // failure, so push it through before releasing the descriptor.
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
        fileHandle = nil
        NotificationCenter.default.removeObserver(self)
    }

    static func defaultLogDirectory(fileManager: FileManager = .default) throws -> URL {
        let libraryDirectory = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    static func logFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(logFileName, isDirectory: false)
    }

    @objc private func applicationDidBecomeActive() {
        log("Application became active")
    }

    @objc private func applicationWillResignActive() {
        log("Application resigned active")
    }

}
