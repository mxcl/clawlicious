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

    func pageSnapshot() async throws -> PageSnapshot {
        guard let webView else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Browser is not ready."])
        }
        guard let result = try await webView.evaluateJavaScript(Self.markdownSnapshotScript) as? [String: Any] else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read browser page content."])
        }
        return PageSnapshot(
            title: result["title"] as? String ?? webView.url?.bookmarkDomain ?? "Untitled",
            description: result["description"] as? String ?? "",
            markdown: result["markdown"] as? String ?? ""
        )
    }

    private static let markdownSnapshotScript = #"""
    (() => {
      const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "SVG", "CANVAS", "BUTTON", "FORM", "INPUT", "TEXTAREA", "SELECT"]);
      const blocks = new Set(["ARTICLE", "MAIN", "SECTION", "DIV", "HEADER", "FOOTER", "BLOCKQUOTE"]);
      const clean = (value) => (value || "").replace(/\s+/g, " ").trim();
      const esc = (value) => clean(value).replace(/([\\`*_{}\[\]()#+\-.!])/g, "\\$1");
      const visible = (el) => {
        const style = getComputedStyle(el);
        return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0";
      };
      const children = (el) => Array.from(el.childNodes).map(md).filter(Boolean);
      const childText = (el) => clean(children(el).join(" "));
      const md = (node) => {
        if (node.nodeType === Node.TEXT_NODE) return esc(node.textContent);
        if (node.nodeType !== Node.ELEMENT_NODE || skip.has(node.tagName) || !visible(node)) return "";

        const tag = node.tagName;
        if (/^H[1-6]$/.test(tag)) return `${"#".repeat(Number(tag[1]))} ${childText(node)}`;
        if (tag === "P") return childText(node);
        if (tag === "BR") return "\n";
        if (tag === "A") {
          const text = childText(node);
          const href = node.getAttribute("href");
          if (!text || !href) return text;
          return `[${text}](${new URL(href, location.href).href})`;
        }
        if (tag === "IMG") return "";
        if (tag === "PRE") return `\`\`\`\n${node.innerText.trim()}\n\`\`\``;
        if (tag === "CODE") return `\`${clean(node.innerText)}\``;
        if (tag === "LI") return `- ${childText(node)}`;
        if (tag === "UL" || tag === "OL") return Array.from(node.children).map(md).filter(Boolean).join("\n");
        if (blocks.has(tag)) return children(node).join("\n\n");
        return children(node).join(" ");
      };

      const articles = Array.from(document.querySelectorAll("article"))
        .filter((el) => clean(el.innerText).length > 80);
      const roots = articles.length ? articles : [document.querySelector("main, [role=main]") || document.body];
      const markdown = roots.map(md).filter(Boolean).join("\n\n---\n\n")
        .replace(/^[ \t]*[-·][ \t]*$/gm, "")
        .replace(/[ \t]+$/gm, "")
        .replace(/\n{3,}/g, "\n\n")
        .trim();

      return {
        title: document.title || "",
        description: document.querySelector("meta[name=description], meta[property='og:description']")?.content || "",
        markdown
      };
    })();
    """#
}

struct BookmarkWebView: NSViewRepresentable {
    var url: URL?
    @ObservedObject var browser: BrowserModel
    var onPageSnapshot: (URL, PageSnapshot) -> Void = { _, _ in }
    var onPageSnapshotFailure: (Error) -> Void = { _ in }

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
        context.coordinator.onPageSnapshot = onPageSnapshot
        context.coordinator.onPageSnapshotFailure = onPageSnapshotFailure
        guard context.coordinator.bookmarkURL != url else { return }
        context.coordinator.bookmarkURL = url
        guard let url else { return }
        webView.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var bookmarkURL: URL?
        var onPageSnapshot: (URL, PageSnapshot) -> Void = { _, _ in }
        var onPageSnapshotFailure: (Error) -> Void = { _ in }
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
            guard let url = webView.url else { return }
            Task {
                do {
                    let snapshot = try await browser.pageSnapshot()
                    onPageSnapshot(url, snapshot)
                } catch {
                    onPageSnapshotFailure(error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            browser.sync(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            browser.sync(from: webView)
        }
    }
}
