import SwiftUI

@main
struct ClawliciousApp: App {
    @NSApplicationDelegateAdaptor(ClawliciousAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1360, height: 820)
    }
}
