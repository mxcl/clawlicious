import SwiftUI

@main
struct ClawliciousApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Bookmark") {
                    NSApp.sendAction(#selector(NSResponder.insertNewline(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
