import SwiftUI
import WebKit
import ClawliciousCore

@MainActor
final class BrowserModel: ObservableObject {
    enum ContentMode {
        case html
        case markdown
    }

    @Published var address = ""
    @Published var contentMode: ContentMode = .html
    @Published private(set) var extractedMarkdown = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        sync(from: webView)
    }

    func sync(from webView: WKWebView) {
        let nextAddress = webView.url?.absoluteString ?? address
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if address != nextAddress { address = nextAddress }
    }

    func prepareForNewPage() {
        contentMode = .html
        extractedMarkdown = ""
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    func showHTML() {
        contentMode = .html
    }

    func showMarkdown() async {
        if extractedMarkdown.isEmpty {
            _ = try? await pageSnapshot()
        }
        contentMode = .markdown
    }

    func pageSnapshot() async throws -> PageSnapshot {
        try await pageSnapshot(minimumMarkdownLength: 0)
    }

    func pageSnapshot(minimumMarkdownLength: Int) async throws -> PageSnapshot {
        var previous = ""
        var stableReadableCount = 0
        for attempt in 0..<20 {
            let snapshot = try await currentPageSnapshot()
            let text = PageExtraction.clean(snapshot.markdown)
            if text.count >= minimumMarkdownLength, PageExtraction.isReadable(snapshot) {
                stableReadableCount = text == previous ? stableReadableCount + 1 : 0
                if stableReadableCount >= 2 {
                    return snapshot
                }
            }
            if attempt == 19 {
                return snapshot
            }
            previous = text
            try await Task.sleep(for: .milliseconds(500))
        }
        return try await currentPageSnapshot()
    }

    nonisolated static func requireReadableMarkdown(_ snapshot: PageSnapshot) throws -> PageSnapshot {
        try PageExtraction.requireReadableMarkdown(snapshot)
    }

    private func currentPageSnapshot() async throws -> PageSnapshot {
        guard let webView else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Browser is not ready."])
        }
        guard let result = try await webView.evaluateJavaScript(PageExtraction.markdownSnapshotScript) as? [String: Any] else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read browser page content."])
        }
        let snapshot = PageSnapshot(
            title: result["title"] as? String ?? webView.url?.bookmarkDomain ?? "Untitled",
            description: result["description"] as? String ?? "",
            markdown: result["markdown"] as? String ?? ""
        )
        extractedMarkdown = snapshot.markdown
        return snapshot
    }
}

struct BookmarkWebView: NSViewRepresentable {
    var url: URL?
    @ObservedObject var browser: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = ToolbarInsetWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.attach(webView)
        guard context.coordinator.bookmarkURL != url else { return }
        context.coordinator.bookmarkURL = url
        guard let url else {
            return
        }
        browser.prepareForNewPage()
        webView.stopLoading()
        webView.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var bookmarkURL: URL?
        private let browser: BrowserModel

        init(browser: BrowserModel) {
            self.browser = browser
        }

        func attach(_ webView: WKWebView) {
            webView.navigationDelegate = self
            (webView as? ToolbarInsetWebView)?.updateToolbarInset()
            browser.attach(webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            (webView as? ToolbarInsetWebView)?.updateToolbarInset()
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? ToolbarInsetWebView)?.updateToolbarInset()
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            browser.sync(from: webView)
        }
    }
}

private final class ToolbarInsetWebView: WKWebView {
    override func layout() {
        super.layout()
        updateToolbarInset()
    }

    func updateToolbarInset() {
        guard let window else { return }
        let top = window.frame.height - window.contentLayoutRect.height
        obscuredContentInsets.top = top
    }
}
