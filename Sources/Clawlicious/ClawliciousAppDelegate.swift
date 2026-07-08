import AppKit
import ClawliciousBrowser
import ClawliciousCore

extension Notification.Name {
    static let clawliciousNewBookmark = Notification.Name("ClawliciousNewBookmark")
    static let clawliciousImportBookmark = Notification.Name("ClawliciousImportBookmark")
    static let clawliciousQueuedImportBookmark = Notification.Name("ClawliciousQueuedImportBookmark")
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installMainMenu()
        }
        MenuBarHelperLauncher.launchIfNeeded()
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clawlicious" {
            guard url.host == "import",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  !urlString.isEmpty else {
                continue
            }
            let background = components.queryItems?.contains { $0.name == "background" && $0.value == "1" } == true
            let notify = components.queryItems?.contains { $0.name == "notify" && $0.value == "1" } == true
            let wasRunning = components.queryItems?.contains { $0.name == "wasRunning" && $0.value == "1" } == true
            ImportURLQueue.shared.enqueue(urlString, notifyOnCompletion: notify)
            if background, !wasRunning {
                NSApp.hide(nil)
                DispatchQueue.main.async {
                    NSApp.hide(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        bookmarkCurrentBrowserPage(from: BrowserApp(NSWorkspace.shared.frontmostApplication))
    }

    func bookmarkCurrentBrowserPage(from app: BrowserApp?) {
        Task { @MainActor in
            do {
                guard let urlString = try await CurrentBrowserURLReader.urlString(from: app) else {
                    let appName = app?.displayName.map { " for \($0)" } ?? ""
                    NotificationCenter.default.post(name: .clawliciousBrowserImportStatus, object: "No supported browser URL found\(appName).")
                    return
                }
                NotificationCenter.default.post(name: .clawliciousImportBookmark, object: urlString)
            } catch {
                NotificationCenter.default.post(name: .clawliciousBrowserImportStatus, object: "Browser URL shortcut failed: \(error.localizedDescription)")
            }
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
