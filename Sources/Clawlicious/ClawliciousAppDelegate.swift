import AppKit

extension Notification.Name {
    static let clawliciousNewBookmark = Notification.Name("ClawliciousNewBookmark")
}

@MainActor
final class ClawliciousAppDelegate: NSObject, NSApplicationDelegate {
    private let menuTarget = MenuTarget()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
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

        let file = NSMenu()
        let new = file.addItem(withTitle: "New Bookmark", action: #selector(MenuTarget.newBookmark(_:)), keyEquivalent: "n")
        new.target = menuTarget
        addMenu(file, named: "File", to: main)

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
}

private extension NSMenu {
    func addItem(submenu: NSMenu, named title: String) {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        addItem(item)
    }
}

private final class MenuTarget: NSObject {
    @objc func newBookmark(_ sender: Any?) {
        NotificationCenter.default.post(name: .clawliciousNewBookmark, object: nil)
    }
}
