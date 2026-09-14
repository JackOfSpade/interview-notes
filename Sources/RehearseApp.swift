import SwiftUI
import SwiftData
import AppKit

@main
public struct RehearseApp: App {
    // Initialize the per-process logger before the data container so startup
    // failures can still leave a diagnostic trail for this session.
    private let sessionLogger = AppSessionLogger.shared
    @StateObject private var dataController = DataController.shared
    @StateObject private var windowManager = WindowManager.shared
    @StateObject private var prefs = AppPreferences.shared

    public init() {
        sessionLogger.log("Application initialized")

        // Ensure regular macOS GUI application activation policy
        NSApplication.shared.setActivationPolicy(.regular)
    }

    public var body: some Scene {
        WindowGroup("Interview Notes") {
            MainWorkspaceView()
                .modelContainer(dataController.container)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            SidebarCommands()

            CommandGroup(after: .windowArrangement) {
                Button(windowManager.isSnapped ? "Unsnap From Camera" : "Snap Below Camera") {
                    windowManager.toggleSnap()
                }
                .keyboardShortcut("c", modifiers: [.control, .command])
            }
        }

        Settings {
            SettingsView()
                .modelContainer(dataController.container)
        }
    }
}
