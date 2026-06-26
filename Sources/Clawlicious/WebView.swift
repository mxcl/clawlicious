import SwiftUI
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var address = ""
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

    func loadAddress() {
        guard let url = browserURL(from: address) else { return }
        webView?.load(URLRequest(url: url))
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.attach(webView)
        guard context.coordinator.bookmarkURL != url else { return }
        context.coordinator.bookmarkURL = url
        guard let url else { return }
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
            browser.attach(webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

func browserURL(from raw: String) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let candidate = value.contains("://") ? value : "https://\(value)"
    guard let url = URL(string: candidate), url.host != nil else { return nil }
    return url
}
