import XCTest
@testable import Rehearse

@MainActor
final class AppSessionLoggerTests: XCTestCase {
    func testStartingSessionTruncatesPreviousLogAndWritesCurrentEntries() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RehearseSessionLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = AppSessionLogger.logFileURL(in: directory)
        try Data("a previous session\n".utf8).write(to: logURL)

        let logger = AppSessionLogger(logDirectory: directory, fileManager: fileManager)
        logger.log("Current-session event")
        logger.finish()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("a previous session"))
        XCTAssertTrue(contents.contains("Session started"))
        XCTAssertTrue(contents.contains("Current-session event"))
        XCTAssertTrue(contents.contains("Session ended"))
        XCTAssertLessThan(
            contents.range(of: "Current-session event")!.lowerBound,
            contents.range(of: "Session ended")!.lowerBound
        )
    }

    func testLogFileURLUsesFixedLastSessionFileName() {
        let directory = URL(fileURLWithPath: "/tmp/Logs/com.rehearse.Rehearse", isDirectory: true)

        XCTAssertEqual(
            AppSessionLogger.logFileURL(in: directory).path,
            "/tmp/Logs/com.rehearse.Rehearse/last-session.log"
        )
    }
}
