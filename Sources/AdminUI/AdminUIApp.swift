import AppKit
import SwiftUI

@main
struct AdminUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Home Theatre Admin") {
            ContentView()
        }
        .defaultSize(width: 1000, height: 720)
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
