import SwiftUI

struct ClawliciousApp: App {
    @NSApplicationDelegateAdaptor(ClawliciousAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1360, height: 820)
    }
}

@main
enum ClawliciousMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--content-probe") {
            ContentProbeCommand.main()
        } else {
            ClawliciousApp.main()
        }
    }
}
