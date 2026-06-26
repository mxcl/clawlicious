import SwiftUI

struct ContentView: View {
    @StateObject private var library = BookmarkLibrary()
    @StateObject private var browser = BrowserModel()
    @State private var bookmarkPendingDeletion: Bookmark?
    @FocusState private var isAddingBookmark: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 290)
        } content: {
            BookmarkListView(library: library, isAddingBookmark: $isAddingBookmark)
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 540)
        } detail: {
            DetailWebView(library: library, bookmark: library.selectedBookmark, browser: browser)
        }
        .toolbar {
            if library.selectedBookmark != nil {
                ToolbarItem(placement: .primaryAction) {
                    BrowserControls(browser: browser)
                }
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
                library.retryBookmark(bookmark)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clawliciousNewBookmark)) { _ in
            isAddingBookmark = true
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

            if !library.categories.isEmpty {
                Section("Categories") {
                    ForEach(library.categories, id: \.self) { category in
                        filterRow(.category(category), icon: "folder")
                    }
                }
            }

            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags, id: \.self) { tag in
                        filterRow(.tag(tag), icon: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search bookmarks")
    }

    private func filterRow(_ filter: BookmarkFilter, icon: String) -> some View {
        Label(filter.title, systemImage: icon)
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
        }
        .controlSize(.small)
    }
}

private struct BookmarkListView: View {
    @ObservedObject var library: BookmarkLibrary
    var isAddingBookmark: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            AddBookmarkField(library: library, isFocused: isAddingBookmark)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            List(library.visibleBookmarks, selection: $library.selectedID) { bookmark in
                BookmarkRow(bookmark: bookmark) {
                    library.retryBookmark(bookmark)
                }
                    .id(bookmark.updatedAt)
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
                .lineLimit(3)
            HStack(spacing: 6) {
                ForEach(bookmark.tags.prefix(4), id: \.self) { tag in
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
            .lineLimit(1)
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
                        onPageSnapshot: { _, page in
                            library.summarizeBookmark(bookmark.id, url: bookmark.url, page: page)
                        },
                        onPageSnapshotFailure: { error in
                            library.failBookmark(bookmark.id, error: error)
                        }
                    )
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
            if bookmark?.status == .pending {
                browser.reload()
            }
        }
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
