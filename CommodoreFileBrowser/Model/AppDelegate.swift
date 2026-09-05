import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the browser is on screen, so state is written out however the
    /// app is asked to quit.
    weak var model: AppModel?

    /// The browser is a single window: closing it should quit, rather than
    /// leave an app running with nothing on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveState()
    }
}
