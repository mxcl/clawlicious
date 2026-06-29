import AppKit
import Carbon.HIToolbox

public struct BrowserApp: Sendable {
    let bundleIdentifier: String?
    let localizedName: String?

    public init(_ app: NSRunningApplication?) {
        bundleIdentifier = app?.bundleIdentifier
        localizedName = app?.localizedName
    }

    public var displayName: String? {
        localizedName ?? bundleIdentifier
    }
}

public enum CurrentBrowserURLReader {
    public static func urlString(from app: BrowserApp?) async throws -> String? {
        guard let browser = browser(for: app) else { return nil }
        return try await Task.detached {
            try requestAutomationPermission(for: browser.automationBundleIdentifier)

            var error: NSDictionary?
            let result = NSAppleScript(source: browser.script)?.executeAndReturnError(&error)
            if let error {
                throw AppleScriptError(error)
            }
            let urlString = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return urlString.isEmpty ? nil : urlString
        }.value
    }

    private static func browser(for app: BrowserApp?) -> BrowserAutomation? {
        switch app?.bundleIdentifier ?? app?.localizedName {
        case "com.apple.Safari", "Safari":
            return BrowserAutomation(
                automationBundleIdentifier: "com.apple.Safari",
                script: #"tell application "Safari" to return URL of current tab of front window"#
            )
        case "com.google.Chrome", "Google Chrome":
            return BrowserAutomation(
                automationBundleIdentifier: "com.google.Chrome",
                script: #"tell application "Google Chrome" to return URL of active tab of front window"#
            )
        case "com.openai.atlas", "ChatGPT Atlas":
            return BrowserAutomation(
                automationBundleIdentifier: "com.openai.atlas",
                script: """
                tell application "ChatGPT Atlas"
                  set fallbackURL to ""
                  repeat with browserWindow in windows
                    set tabURL to URL of active tab of browserWindow
                    if fallbackURL is "" then set fallbackURL to tabURL
                    if tabURL does not contain "ref=mini" and tabURL does not contain "ref=mini-sidebar" then return tabURL
                  end repeat
                  return fallbackURL
                end tell
                """
            )
        case "com.brave.Browser", "Brave Browser":
            return BrowserAutomation(
                automationBundleIdentifier: "com.brave.Browser",
                script: #"tell application "Brave Browser" to return URL of active tab of front window"#
            )
        case "com.microsoft.edgemac", "Microsoft Edge":
            return BrowserAutomation(
                automationBundleIdentifier: "com.microsoft.edgemac",
                script: #"tell application "Microsoft Edge" to return URL of active tab of front window"#
            )
        case "org.mozilla.firefox", "Firefox":
            return BrowserAutomation(
                automationBundleIdentifier: "com.apple.systemevents",
                script: #"tell application "System Events" to tell application process "Firefox" to return value of combo box 1 of group 1 of toolbar "Navigation" of group 1 of front window"#
            )
        case "company.thebrowser.Browser", "Arc":
            return BrowserAutomation(
                automationBundleIdentifier: "company.thebrowser.Browser",
                script: #"tell application "Arc" to return URL of active tab of front window"#
            )
        default:
            return nil
        }
    }

    private static func requestAutomationPermission(for bundleIdentifier: String) throws {
        var target = AEAddressDesc()
        let createStatus = bundleIdentifier.withCString {
            AECreateDesc(typeApplicationBundleID, $0, bundleIdentifier.utf8.count, &target)
        }
        guard createStatus == noErr else {
            throw AppleEventPermissionError(status: OSStatus(createStatus))
        }
        defer { AEDisposeDesc(&target) }

        let permissionStatus = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
        guard permissionStatus == noErr else {
            throw AppleEventPermissionError(status: permissionStatus)
        }
    }
}

private struct BrowserAutomation: Sendable {
    let automationBundleIdentifier: String
    let script: String
}

private struct AppleScriptError: LocalizedError {
    let message: String

    init(_ dictionary: NSDictionary) {
        message = dictionary[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
    }

    var errorDescription: String? { message }
}

private struct AppleEventPermissionError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        switch status {
        case OSStatus(errAEEventNotPermitted):
            "Automation permission was denied."
        case OSStatus(errAEEventWouldRequireUserConsent):
            "Automation permission requires user consent."
        case OSStatus(procNotFound):
            "The browser is not running."
        default:
            "Automation permission failed: \(status)."
        }
    }
}
