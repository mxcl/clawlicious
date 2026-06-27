import AppKit
import Carbon.HIToolbox

private let bookmarkBrowserHotKeySignature = OSType(0x434C4157) // CLAW
private let bookmarkBrowserHotKeyID = UInt32(1)

extension Notification.Name {
    static let clawliciousNewBookmark = Notification.Name("ClawliciousNewBookmark")
    static let clawliciousImportBookmark = Notification.Name("ClawliciousImportBookmark")
    static let clawliciousImportCompleteBookmark = Notification.Name("ClawliciousImportCompleteBookmark")
    static let clawliciousUpdateBookmarkMetadata = Notification.Name("ClawliciousUpdateBookmarkMetadata")
    static let clawliciousBrowserImportStatus = Notification.Name("ClawliciousBrowserImportStatus")
    static let clawliciousDeleteBookmark = Notification.Name("ClawliciousDeleteBookmark")
    static let clawliciousResummarizeBookmark = Notification.Name("ClawliciousResummarizeBookmark")
    static let clawliciousBookmarkSelectionChanged = Notification.Name("ClawliciousBookmarkSelectionChanged")
}

@MainActor
final class ClawliciousAppDelegate: NSObject, NSApplicationDelegate {
    private let menuTarget = MenuTarget()
    private var bookmarkBrowserHotKeyRef: EventHotKeyRef?
    private var bookmarkBrowserHotKeyHandler: EventHandlerRef?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installMainMenu()
            self?.installBookmarkBrowserHotKey()
            NSApp.activate(ignoringOtherApps: true)
        }
        BrowserBookmarkletServer.shared.start()
        Task {
            await CodexAppServerSession.shared.warmUpIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.mainMenu?.items.contains(where: { $0.title == "Edit" }) != true {
            installMainMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let bookmarkBrowserHotKeyRef {
            UnregisterEventHotKey(bookmarkBrowserHotKeyRef)
        }
        if let bookmarkBrowserHotKeyHandler {
            RemoveEventHandler(bookmarkBrowserHotKeyHandler)
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Clawlicious", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Clawlicious", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Clawlicious", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(app, named: "Clawlicious", to: main)

        let bookmark = NSMenu()
        let new = bookmark.addItem(withTitle: "New Bookmark", action: #selector(MenuTarget.newBookmark(_:)), keyEquivalent: "n")
        new.target = menuTarget
        let bookmarkBrowserPage = bookmark.addItem(withTitle: "Bookmark Current Browser Page", action: #selector(MenuTarget.bookmarkCurrentBrowserPage(_:)), keyEquivalent: "b")
        bookmarkBrowserPage.target = menuTarget
        bookmarkBrowserPage.keyEquivalentModifierMask = [.command, .control, .option]
        let copyBookmarklet = bookmark.addItem(withTitle: "Copy Browser Bookmarklet", action: #selector(MenuTarget.copyBrowserBookmarklet(_:)), keyEquivalent: "")
        copyBookmarklet.target = menuTarget
        bookmark.addItem(.separator())
        let resummarize = bookmark.addItem(withTitle: "Resummarize Bookmark", action: #selector(MenuTarget.resummarizeBookmark(_:)), keyEquivalent: "")
        resummarize.target = menuTarget
        let delete = bookmark.addItem(withTitle: "Delete Bookmark", action: #selector(MenuTarget.deleteBookmark(_:)), keyEquivalent: "\u{8}")
        delete.target = menuTarget
        delete.keyEquivalentModifierMask = []
        addMenu(bookmark, named: "Bookmark", to: main)

        addMenu(editMenu(), named: "Edit", to: main)

        let window = NSMenu()
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addMenu(window, named: "Window", to: main)
        NSApp.windowsMenu = window

        addMenu(NSMenu(), named: "Help", to: main)
        NSApp.mainMenu = main
    }

    private func addMenu(_ submenu: NSMenu, named title: String, to main: NSMenu) {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        main.addItem(item)
    }

    private func editMenu() -> NSMenu {
        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: action("undo:"), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: action("redo:"), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: action("pasteAsPlainText:"), keyEquivalent: "V")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(submenu: findMenu(), named: "Find")
        edit.addItem(submenu: spellingMenu(), named: "Spelling and Grammar")
        edit.addItem(submenu: substitutionsMenu(), named: "Substitutions")
        edit.addItem(submenu: transformationsMenu(), named: "Transformations")
        edit.addItem(submenu: speechMenu(), named: "Speech")
        return edit
    }

    private func findMenu() -> NSMenu {
        let find = NSMenu()
        addFindItem("Find...", key: "f", tag: 1, to: find)
        let replace = addFindItem("Find and Replace...", key: "f", tag: 12, to: find)
        replace.keyEquivalentModifierMask = [.command, .option]
        addFindItem("Find Next", key: "g", tag: 2, to: find)
        let previous = addFindItem("Find Previous", key: "G", tag: 3, to: find)
        previous.keyEquivalentModifierMask = [.command, .shift]
        addFindItem("Use Selection for Find", key: "e", tag: 7, to: find)
        addFindItem("Jump to Selection", key: "j", tag: 8, to: find)
        return find
    }

    @discardableResult
    private func addFindItem(_ title: String, key: String, tag: Int, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action("performTextFinderAction:"), keyEquivalent: key)
        item.tag = tag
        return item
    }

    private func spellingMenu() -> NSMenu {
        let spelling = NSMenu()
        spelling.addItem(withTitle: "Show Spelling and Grammar", action: action("showGuessPanel:"), keyEquivalent: ":")
        spelling.addItem(withTitle: "Check Document Now", action: action("checkSpelling:"), keyEquivalent: ";")
        spelling.addItem(.separator())
        spelling.addItem(withTitle: "Check Spelling While Typing", action: action("toggleContinuousSpellChecking:"), keyEquivalent: "")
        spelling.addItem(withTitle: "Check Grammar With Spelling", action: action("toggleGrammarChecking:"), keyEquivalent: "")
        spelling.addItem(withTitle: "Correct Spelling Automatically", action: action("toggleAutomaticSpellingCorrection:"), keyEquivalent: "")
        return spelling
    }

    private func substitutionsMenu() -> NSMenu {
        let substitutions = NSMenu()
        substitutions.addItem(withTitle: "Show Substitutions", action: action("orderFrontSubstitutionsPanel:"), keyEquivalent: "")
        substitutions.addItem(.separator())
        substitutions.addItem(withTitle: "Smart Copy/Paste", action: action("toggleSmartInsertDelete:"), keyEquivalent: "")
        substitutions.addItem(withTitle: "Smart Quotes", action: action("toggleAutomaticQuoteSubstitution:"), keyEquivalent: "")
        substitutions.addItem(withTitle: "Smart Dashes", action: action("toggleAutomaticDashSubstitution:"), keyEquivalent: "")
        substitutions.addItem(withTitle: "Text Replacement", action: action("toggleAutomaticTextReplacement:"), keyEquivalent: "")
        return substitutions
    }

    private func transformationsMenu() -> NSMenu {
        let transformations = NSMenu()
        transformations.addItem(withTitle: "Make Upper Case", action: action("uppercaseWord:"), keyEquivalent: "")
        transformations.addItem(withTitle: "Make Lower Case", action: action("lowercaseWord:"), keyEquivalent: "")
        transformations.addItem(withTitle: "Capitalize", action: action("capitalizeWord:"), keyEquivalent: "")
        return transformations
    }

    private func speechMenu() -> NSMenu {
        let speech = NSMenu()
        speech.addItem(withTitle: "Start Speaking", action: action("startSpeaking:"), keyEquivalent: "")
        speech.addItem(withTitle: "Stop Speaking", action: action("stopSpeaking:"), keyEquivalent: "")
        return speech
    }

    private func action(_ name: String) -> Selector {
        NSSelectorFromString(name)
    }

    private func installBookmarkBrowserHotKey() {
        guard bookmarkBrowserHotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(menuTarget).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard hotKeyID.signature == bookmarkBrowserHotKeySignature, hotKeyID.id == bookmarkBrowserHotKeyID else {
                return noErr
            }

            let target = Unmanaged<MenuTarget>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                target.bookmarkCurrentBrowserPage(nil)
            }
            return noErr
        }, 1, &eventType, userData, &bookmarkBrowserHotKeyHandler)
        guard handlerStatus == noErr else { return }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: bookmarkBrowserHotKeySignature, id: bookmarkBrowserHotKeyID)
        let modifiers = UInt32(cmdKey | controlKey | optionKey)
        let hotKeyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if hotKeyStatus == noErr {
            bookmarkBrowserHotKeyRef = hotKeyRef
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, named title: String) {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        addItem(item)
    }
}

private final class MenuTarget: NSObject, NSMenuItemValidation {
    private var hasSelectedBookmark = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bookmarkSelectionChanged(_:)),
            name: .clawliciousBookmarkSelectionChanged,
            object: nil
        )
    }

    @objc func newBookmark(_ sender: Any?) {
        NotificationCenter.default.post(name: .clawliciousNewBookmark, object: nil)
    }

    @objc func copyBrowserBookmarklet(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserBookmarkletServer.shared.bookmarklet, forType: .string)
        NotificationCenter.default.post(
            name: .clawliciousBrowserImportStatus,
            object: "Browser bookmarklet copied. Create a browser bookmark and paste this as its URL."
        )
    }

    @objc func bookmarkCurrentBrowserPage(_ sender: Any?) {
        do {
            guard let urlString = try CurrentBrowserURLReader.urlString() else {
                NotificationCenter.default.post(name: .clawliciousBrowserImportStatus, object: "No supported browser URL found.")
                return
            }
            NotificationCenter.default.post(name: .clawliciousImportBookmark, object: urlString)
        } catch {
            NotificationCenter.default.post(name: .clawliciousBrowserImportStatus, object: "Browser URL shortcut failed: \(error.localizedDescription)")
        }
    }

    @objc func deleteBookmark(_ sender: Any?) {
        NotificationCenter.default.post(name: .clawliciousDeleteBookmark, object: nil)
    }

    @objc func resummarizeBookmark(_ sender: Any?) {
        NotificationCenter.default.post(name: .clawliciousResummarizeBookmark, object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(deleteBookmark(_:)), #selector(resummarizeBookmark(_:)):
            hasSelectedBookmark
        default:
            true
        }
    }

    @objc private func bookmarkSelectionChanged(_ notification: Notification) {
        hasSelectedBookmark = notification.object != nil
    }
}

private enum CurrentBrowserURLReader {
    static func urlString() throws -> String? {
        guard let script = browserScript(for: NSWorkspace.shared.frontmostApplication) else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            throw AppleScriptError(error)
        }
        let urlString = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return urlString.isEmpty ? nil : urlString
    }

    private static func browserScript(for app: NSRunningApplication?) -> String? {
        switch app?.bundleIdentifier ?? app?.localizedName {
        case "com.apple.Safari", "Safari":
            return #"tell application "Safari" to return URL of current tab of front window"#
        case "com.google.Chrome", "Google Chrome":
            return #"tell application "Google Chrome" to return URL of active tab of front window"#
        case "com.openai.atlas", "ChatGPT Atlas":
            return #"tell application "ChatGPT Atlas" to return URL of active tab of front window"#
        case "com.brave.Browser", "Brave Browser":
            return #"tell application "Brave Browser" to return URL of active tab of front window"#
        case "com.microsoft.edgemac", "Microsoft Edge":
            return #"tell application "Microsoft Edge" to return URL of active tab of front window"#
        case "org.mozilla.firefox", "Firefox":
            return #"tell application "System Events" to tell application process "Firefox" to return value of combo box 1 of group 1 of toolbar "Navigation" of group 1 of front window"#
        case "company.thebrowser.Browser", "Arc":
            return #"tell application "Arc" to return URL of active tab of front window"#
        default:
            return nil
        }
    }
}

private struct AppleScriptError: LocalizedError {
    let message: String

    init(_ dictionary: NSDictionary) {
        message = dictionary[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
    }

    var errorDescription: String? { message }
}
