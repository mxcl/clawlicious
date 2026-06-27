import AppKit
import Darwin
import Foundation
import WebKit
import ClawliciousCore

enum ContentProbeCommand {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let code = await run()
            exit(Int32(code))
        }
        NSApplication.shared.run()
    }

    @MainActor
    private static func run() async -> Int {
        let urls = probeURLs(from: CommandLine.arguments)
        let outputDirectory = FileManager.default.temporaryDirectory.appending(path: "clawlicious-content-probe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let runner = ContentProbeRunner(outputDirectory: outputDirectory)
        var failures = 0
        print("output: \(outputDirectory.path(percentEncoded: false))")
        for url in urls {
            do {
                let result = try await runner.probe(url)
                print("PASS \(url.absoluteString)")
                print("  cookies: \(result.cookieCount)")
                print("  title: \(result.snapshot.title)")
                print("  markdown: \(PageExtraction.clean(result.snapshot.markdown).count) chars")
                print("  file: \(result.outputURL.path(percentEncoded: false))")
            } catch {
                failures += 1
                print("FAIL \(url.absoluteString)")
                print("  \(error.localizedDescription)")
            }
        }
        return failures == 0 ? 0 : 1
    }

    private static func probeURLs(from arguments: [String]) -> [URL] {
        let raw = arguments.drop { $0 != "--content-probe" }.dropFirst()
            .filter { !$0.hasPrefix("--") }
        let values = raw.isEmpty ? [
            "https://example.com",
            "https://x.com/noelcetaSEO/status/2070575448426172926"
        ] : raw
        return values.compactMap(URL.init(string:))
    }
}

@MainActor
private final class ContentProbeRunner: NSObject, WKNavigationDelegate {
    private struct NavigationWaiter {
        var continuation: CheckedContinuation<Void, Error>
    }

    private let outputDirectory: URL
    private let webView: WKWebView
    private var waiter: NavigationWaiter?

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1400), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func probe(_ url: URL) async throws -> ContentProbeResult {
        let request = URLRequest(url: url, timeoutInterval: 60)
        try await load(request)
        let snapshot = try await waitForReadableSnapshot()
        let outputURL = outputDirectory.appending(path: "\(safeName(for: url)).md")
        try snapshot.markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return ContentProbeResult(
            snapshot: snapshot,
            cookieCount: await cookieCount(for: url),
            outputURL: outputURL
        )
    }

    private func load(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiter = NavigationWaiter(continuation: continuation)
            _ = webView.load(request)
            Task {
                try await Task.sleep(for: .seconds(60))
                await MainActor.run {
                    guard self.waiter != nil else { return }
                    self.waiter?.continuation.resume(throwing: NSError(
                        domain: "Clawlicious",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Navigation timed out."]
                    ))
                    self.waiter = nil
                }
            }
        }
    }

    private func waitForReadableSnapshot() async throws -> PageSnapshot {
        var best = PageSnapshot(title: "", description: "", markdown: "")
        var previous = ""
        var stableReadableCount = 0

        for _ in 0..<40 {
            let snapshot = try await currentSnapshot()
            let text = PageExtraction.clean(snapshot.markdown)
            if text.count > PageExtraction.clean(best.markdown).count {
                best = snapshot
            }
            if PageExtraction.isReadable(snapshot), text.count >= 80 {
                stableReadableCount = text == previous ? stableReadableCount + 1 : 0
                if stableReadableCount >= 2 {
                    return snapshot
                }
            }
            previous = text
            try await Task.sleep(for: .milliseconds(500))
        }
        return try PageExtraction.requireReadableMarkdown(best)
    }

    private func currentSnapshot() async throws -> PageSnapshot {
        guard let result = try await webView.evaluateJavaScript(PageExtraction.markdownSnapshotScript) as? [String: Any] else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read browser page content."])
        }
        return PageSnapshot(
            title: result["title"] as? String ?? webView.url?.bookmarkDomain ?? "Untitled",
            description: result["description"] as? String ?? "",
            markdown: result["markdown"] as? String ?? ""
        )
    }

    private func cookieCount(for url: URL) async -> Int {
        guard let host = url.host(percentEncoded: false) ?? url.host else { return 0 }
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { cookie in
                    host == cookie.domain || host.hasSuffix(cookie.domain.trimmingPrefix("."))
                }.count)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            waiter?.continuation.resume()
            waiter = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            waiter?.continuation.resume(throwing: error)
            waiter = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            waiter?.continuation.resume(throwing: error)
            waiter = nil
        }
    }

    private func safeName(for url: URL) -> String {
        url.absoluteString
            .replacing(/[^A-Za-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct ContentProbeResult {
    var snapshot: PageSnapshot
    var cookieCount: Int
    var outputURL: URL
}
