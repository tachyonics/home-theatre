import AppKit
import SwiftUI

@main
struct AdminUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Shared rather than owned by `ContentView`: the review window is a separate
    /// scene, and could not reach state held inside another scene's view.
    @State private var changes = ChangeStore()

    var body: some Scene {
        WindowGroup("Home Theatre Admin") {
            ContentView()
                .environment(changes)
        }
        .defaultSize(width: 1000, height: 720)

        // A single window, not a group: there is one queue, so a second copy of the
        // list would only ever disagree with the first about what is selected.
        Window("Pending Changes", id: PendingChangesWindow.id) {
            PendingChangesView()
                .environment(changes)
        }
        .defaultSize(width: 860, height: 460)
    }
}

/// Run as a bare SwiftPM executable there is no app bundle, so the process starts
/// as an accessory and never takes focus. Promoting it to a regular app gives it a
/// Dock icon, a menu bar, and a window that comes to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum PendingChangesWindow {
    static let id = "pending-changes"
}
