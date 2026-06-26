import Foundation
import Network

final class BrowserBookmarkletServer: @unchecked Sendable {
    static let shared = BrowserBookmarkletServer()

    private let port: UInt16 = 45873
    private let queue = DispatchQueue(label: "clawlicious.browser-bookmarklet")
    private let tokenKey = "BrowserBookmarkletToken"
    private var listener: NWListener?

    private init() {}

    var bookmarklet: String {
        let endpoint = "http://127.0.0.1:\(port)/add?token=\(token)&url="
        return "javascript:(()=>{open('\(endpoint)'+encodeURIComponent(location.href),'clawlicious','popup,width=420,height=220')})()"
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address("127.0.0.1")!),
                port: nwPort
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NotificationCenter.default.post(
                name: .clawliciousBrowserImportStatus,
                object: "Browser bookmarklet server failed: \(error.localizedDescription)"
            )
        }
    }

    private var token: String {
        if let token = UserDefaults.standard.string(forKey: tokenKey) {
            return token
        }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: tokenKey)
        return token
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                Self.respond("Bad request.", status: "400 Bad Request", on: connection)
                return
            }

            if let urlString = Self.importURLString(from: request, expectedToken: self.token) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .clawliciousImportBookmark, object: urlString)
                }
                Self.respond("Sent to Clawlicious.", on: connection)
            } else {
                Self.respond("Forbidden.", status: "403 Forbidden", on: connection)
            }
        }
    }

    static func importURLString(from request: String, expectedToken: String) -> String? {
        guard let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/add",
              components.queryItems?.first(where: { $0.name == "token" })?.value == expectedToken,
              let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !urlString.isEmpty else {
            return nil
        }
        return urlString
    }

    private static func respond(_ body: String, status: String = "200 OK", on connection: NWConnection) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>Clawlicious</title><body>\(body)</body>
        """
        let data = Data(html.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
