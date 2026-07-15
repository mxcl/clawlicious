import AppKit
import Carbon.HIToolbox
import ClawliciousBrowser
import ClawliciousCore
import ServiceManagement
import SwiftUI

private let hotKeySignature = OSType(0x434C4157) // CLAW
private let hotKeyID = UInt32(1)

@main
struct ClawliciousMenuBarHelperApp: App {
    @NSApplicationDelegateAdaptor(HelperDelegate.self) private var delegate
    @StateObject private var worker = BookmarkImportWorker.shared

    var body: some Scene {
        MenuBarExtra {
            HelperMenuView()
        } label: {
            Image(systemName: worker.iconState.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(worker.iconState.color)
                .accessibilityLabel("Clawlicious")
        }
    }
}

private extension MenuBarIconState {
    var systemImage: String {
        switch self {
        case .idle, .processingFlash: "bookmark"
        case .processing, .success, .failure: "bookmark.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        default: .primary
        }
    }
}

private struct HelperMenuView: View {
    @StateObject private var helperStatus = HelperStatus.shared
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

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

            if let status = helperStatus.message {
                Divider()
                Text(status)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }.keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func bookmarkCurrentBrowserPage() async {
        helperStatus.show(await HelperActions.bookmarkCurrentBrowserPage())
    }

    private func setStartsAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startsAtLogin = enabled
            helperStatus.show(nil)
        } catch {
            startsAtLogin = SMAppService.mainApp.status == .enabled
            helperStatus.show(error.localizedDescription)
        }
    }

    private func openMainApp() {
        guard HelperActions.openMainApp() else {
            helperStatus.show("Could not open Clawlicious.")
            return
        }
    }
}

@MainActor
final class HelperStatus: ObservableObject {
    static let shared = HelperStatus()

    @Published private(set) var message: String?

    private var observer: NSObjectProtocol?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ClawliciousStatusNotification.name,
            object: nil,
            queue: .main
        ) { notification in
            guard let message = notification.userInfo?[ClawliciousStatusNotification.messageKey] as? String else { return }
            Task { @MainActor in
                self.show(message)
            }
        }
    }

    func show(_ message: String?) {
        self.message = message
        guard let message else {
            panel?.close()
            return
        }
        showPanel(message)
    }

    private func showPanel(_ message: String) {
        hideTask?.cancel()

        let controller = NSHostingController(rootView: HelperStatusToast(message: message))
        let size = controller.sizeThatFits(in: NSSize(width: 340, height: 120))
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let frame = NSRect(
            x: screenFrame.maxX - size.width - 14,
            y: screenFrame.maxY - size.height - 32,
            width: size.width,
            height: size.height
        )

        let panel = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.setFrame(frame, display: true)
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.panel?.close() }
        }
    }
}

private struct HelperStatusToast: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary)
            }
            .padding(1)
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installHotKey()
        BrowserBookmarkletServer.shared.start { command in
            Task { @MainActor in BookmarkImportWorker.shared.enqueue(command) }
        }
        Task { await CodexAppServerSession.shared.warmUpIfNeeded() }
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
                HelperStatus.shared.show(await HelperActions.bookmarkCurrentBrowserPage())
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
            BookmarkImportWorker.shared.enqueue(.importURL(urlString))
            return "Added bookmark. Summarizing..."
        } catch {
            return error.localizedDescription
        }
    }

    static func openMainApp() -> Bool {
        guard let url = URL(string: "clawlicious://open") else { return false }
        return NSWorkspace.shared.open(url)
    }

}
