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

        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu(edit, named: "Edit", to: main)

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
}

private final class MenuTarget: NSObject {
    @objc func newBookmark(_ sender: Any?) {
        NotificationCenter.default.post(name: .clawliciousNewBookmark, object: nil)
    }
}
