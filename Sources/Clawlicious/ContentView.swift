import AppKit
import ClawliciousCore
import SwiftUI

struct ContentView: View {
    @StateObject private var library = BookmarkLibrary(commandClient: .clawlicious)
    @StateObject private var browser = BrowserModel()
    @State private var bookmarkPendingDeletion: Bookmark?
    @State private var isAddingBookmark = false

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } content: {
            BookmarkListView(library: library)
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 540)
                .toolbar {
                    ToolbarItem {
                        CodexAgentButton(library: library)
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItem {
                        AddBookmarkButton(library: library, isPresented: $isAddingBookmark)
                    }
                }
        } detail: {
            DetailWebView(bookmark: library.selectedBookmark, browser: browser)
                .ignoresSafeArea(edges: .top)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .toolbar {
                    if library.selectedBookmark != nil {
                        ToolbarItem {
                            Button {
                                browser.goBack()
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!browser.canGoBack)
                            .help("Back")
                        }
                        ToolbarItem {
                            Button {
                                browser.goForward()
                            } label: {
                                Label("Forward", systemImage: "chevron.right")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!browser.canGoForward)
                            .help("Forward")
                        }
                        ToolbarSpacer()
                        ToolbarItem {
                            Text(browser.address.isEmpty ? "Website" : browser.address)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                        }
                        ToolbarSpacer()
                        ToolbarItem {
                            Button {
                                browser.isLoading ? browser.stopLoading() : browser.reload()
                            } label: {
                                Label(
                                    browser.isLoading ? "Stop" : "Reload",
                                    systemImage: browser.isLoading ? "xmark" : "arrow.clockwise"
                                )
                                .labelStyle(.iconOnly)
                            }
                            .help(browser.isLoading ? "Stop" : "Reload")
                        }
                        ToolbarItem {
                            Button {
                                if browser.contentMode == .html {
                                    Task { await browser.showMarkdown() }
                                } else {
                                    browser.showHTML()
                                }
                            } label: {
                                Label(
                                    browser.contentMode == .html ? "Show extracted Markdown" : "Show webpage",
                                    systemImage: browser.contentMode == .html ? "doc.plaintext" : "globe"
                                )
                                .labelStyle(.iconOnly)
                            }
                            .help(browser.contentMode == .html ? "Show extracted Markdown" : "Show webpage")
                        }
                    }
                }
        }
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .background {
            LiquidGlassSurface(material: .regularMaterial, tint: .clear)
                .ignoresSafeArea()
        }
        .background(WindowChrome())
        .frame(minWidth: 1120, minHeight: 680)
        .onAppear {
            publishBookmarkSelection()
        }
        .onChange(of: library.selectedID) { _, _ in publishBookmarkSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousDeleteBookmark)) { _ in
            bookmarkPendingDeletion = library.selectedBookmark
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousResummarizeBookmark)) { _ in
            if let bookmark = library.selectedBookmark {
                library.resummarizeBookmark(bookmark)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousNewBookmark)) { _ in
            isAddingBookmark = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousBrowserImportStatus)) { notification in
            if let message = notification.object as? String {
                library.statusLine = message
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: ClawliciousLibraryNotification.name)) { notification in
            let id = (notification.userInfo?[ClawliciousLibraryNotification.bookmarkIDKey] as? String)
                .flatMap(UUID.init(uuidString:))
            library.reload(selecting: id)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: ClawliciousStatusNotification.name)) { notification in
            if let message = notification.userInfo?[ClawliciousStatusNotification.messageKey] as? String {
                library.statusLine = message
            }
        }
        .alert("Delete Bookmark?", isPresented: deleteConfirmationPresented, presenting: bookmarkPendingDeletion) { bookmark in
            Button("Delete", role: .destructive) {
                library.deleteBookmark(bookmark.id)
                bookmarkPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                bookmarkPendingDeletion = nil
            }
        } message: { bookmark in
            Text("Delete \"\(bookmark.title)\"?")
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding {
            bookmarkPendingDeletion != nil
        } set: { isPresented in
            if !isPresented {
                bookmarkPendingDeletion = nil
            }
        }
    }

    private func publishBookmarkSelection() {
        NotificationCenter.default.post(name: .clawliciousBookmarkSelectionChanged, object: library.selectedBookmark?.id)
    }

}

private struct SidebarView: View {
    @ObservedObject var library: BookmarkLibrary

    var body: some View {
        List(selection: $library.filter) {
            filterRow(.all, icon: "tray.full")

            if !library.visibleCategories.isEmpty {
                Section("Categories") {
                    ForEach(library.visibleCategories, id: \.self) { category in
                        filterRow(.category(category), icon: "folder")
                    }
                }
            }

            if !library.visibleTags.isEmpty {
                Section("Tags") {
                    ForEach(library.visibleTags, id: \.self) { tag in
                        filterRow(.tag(tag), icon: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search bookmarks")
        .onChange(of: library.searchText) { _, _ in
            library.resetFilterIfEmpty()
        }
    }

    private func filterRow(_ filter: BookmarkFilter, icon: String) -> some View {
        HStack {
            Label(filter.title, systemImage: icon)
            Spacer()
            Text("\(library.count(for: filter))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
            .tag(filter)
    }
}

private struct CodexAgentButton: View {
    @ObservedObject var library: BookmarkLibrary

    var body: some View {
        Button(action: openCodexAgentPrompt) {
            Label("Open Codex", systemImage: "sparkles")
                .labelStyle(.iconOnly)
        }
        .help("Open Codex with agent connection instructions")
    }

    private func openCodexAgentPrompt() {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: BrowserBookmarkletServer.shared.agentConnectionText)
        ]

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            library.statusLine = "Could not open Codex."
            return
        }

        library.statusLine = "Opened Codex with agent connection instructions."
    }
}

private struct AddBookmarkButton: View {
    @ObservedObject var library: BookmarkLibrary
    @Binding var isPresented: Bool
    @FocusState private var isURLFocused: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Add Bookmark", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .help("Add bookmark")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HStack {
                TextField("Bookmark URL", text: $library.newURLString)
                    .focused($isURLFocused)
                    .onSubmit(addBookmark)

                Button("OK", action: addBookmark)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(width: 360)
            .onAppear {
                isURLFocused = true
            }
        }
    }

    private func addBookmark() {
        guard library.addBookmark(library.newURLString) else { return }
        library.newURLString = ""
        isPresented = false
    }
}

private struct BookmarkListView: View {
    @ObservedObject var library: BookmarkLibrary

    var body: some View {
        List(library.visibleBookmarks, selection: $library.selectedID) { bookmark in
            BookmarkRow(bookmark: bookmark) {
                library.retryBookmark(bookmark)
            }
                .id(bookmark.updatedAt)
                .tag(bookmark.id)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BookmarkRow: View {
    var bookmark: Bookmark
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(bookmark.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let warning = bookmark.contentWarning {
                    WarningBadge(message: warning)
                }
                if bookmark.status == .failed {
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Retry Codex metadata")
                }
                StatusDot(status: bookmark.status)
            }
            Text(bookmark.domain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(bookmark.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TagFlow(spacing: 6) {
                ForEach(bookmark.tags, id: \.self) { tag in
                    TagPill(tag, systemImage: "tag")
                }
                TagPill(bookmark.category, systemImage: "folder")
            }
        }
        .padding(.vertical, 6)
        .help(bookmark.error ?? bookmark.url.absoluteString)
    }
}

private struct WarningBadge: View {
    var message: String
    @State private var isPresented = false

    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { isPresented = $0 }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(10)
            }
            .accessibilityLabel("Bookmark content warning")
            .accessibilityValue(message)
    }
}

private struct TagFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY

        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX

            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }

            y += row.height + spacing
        }
    }

    private func rows(in proposedWidth: CGFloat?, subviews: Subviews) -> [Row] {
        let maxWidth = proposedWidth ?? .greatestFiniteMagnitude
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let measured = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let item = Item(index: index, size: CGSize(width: min(measured.width, maxWidth), height: measured.height))

            if !row.items.isEmpty, row.width + spacing + item.size.width > maxWidth {
                rows.append(row)
                row = Row()
            }

            row.append(item, spacing: spacing)
        }

        if !row.items.isEmpty {
            rows.append(row)
        }

        return rows
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: Item, spacing: CGFloat) {
            if !items.isEmpty {
                width += spacing
            }
            items.append(item)
            width += item.size.width
            height = max(height, item.size.height)
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }
}

private struct StatusDot: View {
    var status: Bookmark.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(status.rawValue)
            .accessibilityLabel("Status")
            .accessibilityValue(status.rawValue.capitalized)
    }

    private var color: Color {
        switch status {
        case .pending: .yellow
        case .summarized: .green
        case .failed: .red
        }
    }
}

private struct TagPill: View {
    var text: String
    var systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct DetailWebView: View {
    var bookmark: Bookmark?
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Group {
            if let bookmark {
                ZStack {
                    BookmarkWebView(
                        url: bookmark.url,
                        browser: browser
                    )
                    .id(bookmark.id)
                    .opacity(browser.contentMode == .html ? 1 : 0)
                    .allowsHitTesting(browser.contentMode == .html)

                    if browser.contentMode == .markdown {
                        MarkdownSourceView(markdown: browser.extractedMarkdown)
                    }
                }
            } else {
                ContentUnavailableView("No Bookmark", systemImage: "link", description: Text("Add a URL to start."))
            }
        }
        .background(.background)
    }
}

private struct MarkdownSourceView: View {
    var markdown: String

    var body: some View {
        ScrollView {
            Text(markdown.isEmpty ? "No markdown extracted yet." : markdown)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.background)
    }
}

private struct LiquidGlassSurface: View {
    var material: Material
    var tint: Color

    var body: some View {
        Rectangle()
            .fill(material)
            .overlay(tint)
            .backgroundExtensionEffect()
    }
}
