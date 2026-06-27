import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var library = BookmarkLibrary()
    @StateObject private var browser = BrowserModel()
    @State private var bookmarkPendingDeletion: Bookmark?
    @State private var bookmarkColumnWidth: CGFloat = 430
    @State private var detailColumnWidth: CGFloat = 620
    @FocusState private var isAddingBookmark: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } content: {
            BookmarkListView(library: library)
                .background(ColumnWidthReporter(width: $bookmarkColumnWidth))
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 540)
        } detail: {
            DetailWebView(library: library, bookmark: library.selectedBookmark, browser: browser)
                .background(ColumnWidthReporter(width: $detailColumnWidth))
        }
        .background {
            GeometryReader { proxy in
                TitlebarControls(
                    library: library,
                    browser: browser,
                    isAddingBookmark: $isAddingBookmark,
                    hasBookmark: library.selectedBookmark != nil,
                    totalWidth: proxy.size.width,
                    bookmarkColumnWidth: bookmarkColumnWidth,
                    detailColumnWidth: detailColumnWidth
                )
            }
        }
        .background {
            LiquidGlassSurface(material: .ultraThinMaterial, tint: .black.opacity(0.14))
                .ignoresSafeArea()
        }
        .background(WindowChrome())
        .frame(minWidth: 1120, minHeight: 680)
        .onAppear(perform: publishBookmarkSelection)
        .onChange(of: library.selectedID) { _, _ in publishBookmarkSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousDeleteBookmark)) { _ in
            bookmarkPendingDeletion = library.selectedBookmark
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousResummarizeBookmark)) { _ in
            if let bookmark = library.selectedBookmark {
                Task {
                    do {
                        let page = try await browser.pageSnapshot()
                        library.resummarizeBookmark(bookmark, page: page)
                    } catch {
                        library.failResummarizeBookmark(bookmark, error: error)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousNewBookmark)) { _ in
            isAddingBookmark = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousImportBookmark)) { notification in
            guard let urlString = notification.object as? String else { return }
            library.addBookmark(urlString)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousImportCompleteBookmark)) { notification in
            guard let bookmark = notification.object as? Bookmark else { return }
            library.addCompleteBookmark(bookmark)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousUpdateBookmarkMetadata)) { notification in
            guard let bookmark = notification.object as? Bookmark else { return }
            library.updateBookmarkMetadata(bookmark)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousBrowserImportStatus)) { notification in
            if let message = notification.object as? String {
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

private struct AddBookmarkField: View {
    @ObservedObject var library: BookmarkLibrary
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            TextField("Add bookmark URL", text: $library.newURLString)
                .textFieldStyle(.roundedBorder)
                .focused(isFocused)
                .onSubmit { library.addBookmarkFromField() }
            Button {
                library.addBookmarkFromField()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add bookmark")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(BrowserBookmarkletServer.shared.agentConnectionText, forType: .string)
                library.statusLine = "Agent app connection text copied."
            } label: {
                Label("Connect Agent App", systemImage: "link")
            }
            .buttonStyle(.borderless)
            .help("Copy agent app connection instructions")
        }
        .controlSize(.small)
    }
}

private struct BookmarkListView: View {
    @ObservedObject var library: BookmarkLibrary

    var body: some View {
        VStack(spacing: 0) {
            List(library.visibleBookmarks, selection: $library.selectedID) { bookmark in
                BookmarkRow(bookmark: bookmark) {
                    library.retryBookmark(bookmark)
                }
                    .tag(bookmark.id)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            Text(library.statusLine.isEmpty ? "\(library.visibleBookmarks.count) bookmarks" : library.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .background(LiquidGlassSurface(material: .thinMaterial, tint: .white.opacity(0.025)))
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
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct DetailWebView: View {
    @ObservedObject var library: BookmarkLibrary
    var bookmark: Bookmark?
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Group {
            if let bookmark {
                ZStack {
                    BookmarkWebView(
                        url: bookmark.url,
                        browser: browser,
                        onPageSnapshot: { requestedURL, page in
                            library.refreshBookmarkMarkdown(bookmark.id, url: requestedURL, page: page)
                            library.summarizeBookmark(bookmark.id, url: requestedURL, page: page)
                        },
                        onPageSnapshotFailure: { error in
                            library.failBookmark(bookmark.id, error: error)
                        }
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
        .onChange(of: bookmark?.updatedAt) { _, _ in
            if bookmark?.status == .pending, browser.extractedMarkdown.isEmpty {
                browser.reload()
            }
        }
    }
}

private struct ColumnWidthReporter: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
        }
    }
}

private struct TitlebarControls: NSViewRepresentable {
    @ObservedObject var library: BookmarkLibrary
    @ObservedObject var browser: BrowserModel
    var isAddingBookmark: FocusState<Bool>.Binding
    var hasBookmark: Bool
    var totalWidth: CGFloat
    var bookmarkColumnWidth: CGFloat
    var detailColumnWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(
                window: view.window,
                library: library,
                browser: browser,
                isAddingBookmark: isAddingBookmark,
                hasBookmark: hasBookmark,
                totalWidth: totalWidth,
                bookmarkColumnWidth: bookmarkColumnWidth,
                detailColumnWidth: detailColumnWidth
            )
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeAccessory()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var controller: NSTitlebarAccessoryViewController?
        private var hostingView: PassthroughHostingView<TitlebarControlsContent>?

        func update(
            window newWindow: NSWindow?,
            library: BookmarkLibrary,
            browser: BrowserModel,
            isAddingBookmark: FocusState<Bool>.Binding,
            hasBookmark: Bool,
            totalWidth: CGFloat,
            bookmarkColumnWidth: CGFloat,
            detailColumnWidth: CGFloat
        ) {
            guard let newWindow else {
                removeAccessory()
                return
            }

            if window !== newWindow {
                removeAccessory()
                window = newWindow
            }

            let width = max(0, totalWidth)
            let rootView = TitlebarControlsContent(
                library: library,
                browser: browser,
                isAddingBookmark: isAddingBookmark,
                hasBookmark: hasBookmark,
                totalWidth: width,
                bookmarkColumnWidth: bookmarkColumnWidth,
                detailColumnWidth: detailColumnWidth
            )

            if let hostingView {
                hostingView.rootView = rootView
                hostingView.frame.size = NSSize(width: width, height: Self.height)
            } else {
                let hostingView = PassthroughHostingView(rootView: rootView)
                hostingView.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
                self.hostingView = hostingView

                let controller = NSTitlebarAccessoryViewController()
                controller.layoutAttribute = .right
                controller.view = hostingView
                self.controller = controller
                newWindow.addTitlebarAccessoryViewController(controller)
            }
        }

        func removeAccessory() {
            guard let controller else { return }
            if let window, let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === controller }) {
                window.removeTitlebarAccessoryViewController(at: index)
            } else {
                controller.removeFromParent()
            }
            self.controller = nil
            self.hostingView = nil
        }

        private static let height: CGFloat = 52
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }
}

private struct TitlebarControlsContent: View {
    @ObservedObject var library: BookmarkLibrary
    @ObservedObject var browser: BrowserModel
    var isAddingBookmark: FocusState<Bool>.Binding
    var hasBookmark: Bool
    var totalWidth: CGFloat
    var bookmarkColumnWidth: CGFloat
    var detailColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: sidebarWidth)
                .allowsHitTesting(false)

            AddBookmarkField(library: library, isFocused: isAddingBookmark)
                .padding(.horizontal, 10)
                .frame(width: bookmarkColumnWidth)

            if hasBookmark {
                BrowserControls(browser: browser)
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .frame(width: detailColumnWidth, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: detailColumnWidth)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: totalWidth, height: 52, alignment: .leading)
        .allowsHitTesting(true)
    }

    private var sidebarWidth: CGFloat {
        max(0, totalWidth - bookmarkColumnWidth - detailColumnWidth)
    }
}

private struct BrowserControls: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("Back")

            Button {
                browser.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("Forward")

            Button {
                browser.isLoading ? browser.stopLoading() : browser.reload()
            } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(browser.isLoading ? "Stop" : "Reload")

            Button {
                if browser.contentMode == .html {
                    Task { await browser.showMarkdown() }
                } else {
                    browser.showHTML()
                }
            } label: {
                Image(systemName: browser.contentMode == .html ? "doc.plaintext" : "globe")
            }
            .help(browser.contentMode == .html ? "Show extracted Markdown" : "Show webpage")

            Text(browser.address.isEmpty ? "Website" : browser.address)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
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
