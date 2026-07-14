import AppKit

enum MenuBarHelperLauncher {
    private static let bundleIdentifier = "dev.mxcl.clawlicious.menubar"
    private static let appName = "Clawlicious Menu.app"

    static func launchIfNeeded() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              let helperURL else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error {
                NSLog("Clawlicious menu bar helper failed to launch: \(error.localizedDescription)")
            }
        }
    }

    private static var helperURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents")
            .appending(path: "Library")
            .appending(path: "LoginItems")
            .appending(path: appName)
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }
}
