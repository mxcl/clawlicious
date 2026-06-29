import AppKit
import Carbon.HIToolbox
import ClawliciousBrowser
import ServiceManagement
import SwiftUI

private let hotKeySignature = OSType(0x434C4157) // CLAW
private let hotKeyID = UInt32(1)

@main
struct ClawliciousMenuBarHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Clawlicious", systemImage: "bookmark") {
            HelperMenuView()
        }
    }
}

private struct HelperMenuView: View {
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled
    @State private var status: String?

    var body: some View {
        Group {
            Button("Bookmark Current Browser Page") {
                Task { await bookmarkCurrentBrowserPage() }
            }
            .keyboardShortcut("b", modifiers: [.command, .control, .option])

            Button("Open Clawlicious") {
                openMainApp()
            }

            Toggle("Start at Login", isOn: Binding {
                startsAtLogin
            } set: { enabled in
                setStartsAtLogin(enabled)
            })

            if let status {
                Divider()
                Text(status)
            }

            Divider()

            Button("Quit Menu Bar Helper") {
                NSApp.terminate(nil)
            }
        }
    }

    private func bookmarkCurrentBrowserPage() async {
        status = await HelperActions.bookmarkCurrentBrowserPage()
    }

    private func setStartsAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startsAtLogin = enabled
            status = nil
        } catch {
            startsAtLogin = SMAppService.mainApp.status == .enabled
            status = error.localizedDescription
        }
    }

    private func openMainApp(importing urlString: String? = nil) {
        guard HelperActions.openMainApp(importing: urlString) else {
            status = "Could not open Clawlicious."
            return
        }
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    private func installHotKey() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }

            var receivedHotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &receivedHotKeyID
            )

            guard receivedHotKeyID.signature == hotKeySignature, receivedHotKeyID.id == hotKeyID else {
                return noErr
            }

            Task { @MainActor in
                _ = await HelperActions.bookmarkCurrentBrowserPage()
            }
            return noErr
        }, 1, &eventType, nil, &hotKeyHandler)
        guard handlerStatus == noErr else { return }

        var ref: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | controlKey | optionKey), keyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
    }
}

@MainActor
private enum HelperActions {
    static func bookmarkCurrentBrowserPage() async -> String {
        let app = BrowserApp(NSWorkspace.shared.frontmostApplication)
        do {
            guard let urlString = try await CurrentBrowserURLReader.urlString(from: app) else {
                return "No supported browser URL found."
            }
            return openMainApp(importing: urlString) ? "Sent page to Clawlicious." : "Could not open Clawlicious."
        } catch {
            return error.localizedDescription
        }
    }

    static func openMainApp(importing urlString: String? = nil) -> Bool {
        guard var components = URLComponents(string: "clawlicious://open") else { return false }
        if let urlString {
            components.host = "import"
            components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        }
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
