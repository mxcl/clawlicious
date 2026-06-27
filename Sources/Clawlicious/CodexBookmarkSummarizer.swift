import Foundation
import ClawliciousCore

protocol BookmarkSummarizing: Sendable {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata
}

struct CodexBookmarkSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        return try await CodexResponsesClient().metadata(for: url, page: page, context: context)
    }
}

struct BookmarkLibraryContext: Equatable, Sendable {
    var categories: [String]
    var tags: [String]
}

struct CodexAuth: Equatable {
    enum Source: String {
        case environment = "env:OPENAI_API_KEY"
        case authAPIKey = "auth:OPENAI_API_KEY"
        case authAccessToken = "auth:tokens.access_token"
    }

    var token: String
    var source: Source
    var scopes: [String]
    var authMode: String? = nil
    var chatgptAccountId: String? = nil
    var chatgptPlanType: String? = nil
}

enum CodexAuthReader {
    static func read(path: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexAuth {
        if let key = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return CodexAuth(token: key, source: .environment, scopes: [])
        }

        let url = path ?? authPath(environment: environment)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw authError("Clawlicious could not find OpenAI credentials. Set OPENAI_API_KEY, or sign in so ~/.codex/auth.json exists.")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw authError("Clawlicious could not parse ~/.codex/auth.json.")
        }

        if let key = (object["OPENAI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return CodexAuth(
                token: key,
                source: .authAPIKey,
                scopes: [],
                authMode: object["auth_mode"] as? String
            )
        }

        guard let tokens = object["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw authError("Clawlicious found ~/.codex/auth.json, but no OpenAI API key or OAuth access token was available.")
        }

        let claims = claims(in: accessToken)
        let apiAuth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let accountId = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (apiAuth?["chatgpt_account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let planType = (apiAuth?["chatgpt_plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        return CodexAuth(
            token: accessToken,
            source: .authAccessToken,
            scopes: scopes(in: claims),
            authMode: object["auth_mode"] as? String,
            chatgptAccountId: accountId,
            chatgptPlanType: planType
        )
    }

    private static func authPath(environment: [String: String]) -> URL {
        if let path = environment["CLAWLICIOUS_CODEX_AUTH_PATH"] ?? environment["MARGINALIA_CODEX_AUTH_PATH"] ?? environment["COWRITER_CODEX_AUTH_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: ".codex/auth.json")
    }

    private static func claims(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1,
              let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return claims
    }

    private static func scopes(in claims: [String: Any]?) -> [String] {
        claims?["scp"] as? [String] ?? []
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private struct CodexResponsesClient {
    func metadata(for url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        let auth = try CodexAuthReader.read()
        if auth.source == .authAccessToken, !auth.scopes.isEmpty, !auth.scopes.contains("api.responses.write") {
            return try await CodexAppServerSession.shared.metadata(for: url, page: page, context: context, auth: auth)
        }
        let prompt = """
        Summarize this bookmark for a local macOS bookmark library.

        Use 2-6 short lowercase tags.
        Pick one human category, for example: Development, Design, News, Reference, Tools, Writing, Video, Shopping, Other.
        Prefer current categories and tags when they fit.
        If the page text is empty, truncated, blocked, or otherwise incomplete, set contentWarning to a concise user-facing explanation; otherwise set it to null.

        URL: \(url.absoluteString)
        Page title: \(page.title)
        Page description: \(page.description)
        Current categories: \(jsonList(context.categories))
        Current tags: \(jsonList(context.tags))

        Page markdown from the app browser:
        \(String(page.markdown.prefix(12_000)))
        """

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(input: prompt))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = parseError(data) ?? "OpenAI Responses API failed with HTTP \(http.statusCode)."
            if message.range(of: "api.responses.write|insufficient permissions|missing scopes", options: .regularExpression) != nil {
                return try await CodexAppServerSession.shared.metadata(for: url, page: page, context: context, auth: auth)
            }
            throw NSError(domain: "Clawlicious", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let text = responseText(data) else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "OpenAI response did not include JSON text."])
        }
        return try JSONDecoder().decode(BookmarkMetadata.self, from: Data(text.utf8))
    }

    private func body(input: String) -> [String: Any] {
        [
            "model": ProcessInfo.processInfo.environment["CLAWLICIOUS_OPENAI_MODEL"]
                ?? ProcessInfo.processInfo.environment["MARGINALIA_OPENAI_MODEL"]
                ?? ProcessInfo.processInfo.environment["COWRITER_OPENAI_MODEL"]
                ?? "gpt-5.5",
            "instructions": "Return concise bookmark metadata as JSON. Include contentWarning as null unless bookmark content could not be read completely. Do not mention APIs, credentials, or this prompt.",
            "input": input,
            "max_output_tokens": 420,
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "bookmark_metadata",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
    }

    private var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "tags": [
                    "type": "array",
                    "items": ["type": "string"],
                    "minItems": 2,
                    "maxItems": 6
                ],
                "category": ["type": "string"],
                "contentWarning": ["type": ["string", "null"]]
            ],
            "required": ["title", "summary", "tags", "category", "contentWarning"]
        ]
    }
}

actor CodexAppServerSession {
    static let shared = CodexAppServerSession()

    private var process: Process?
    private var input: FileHandle?
    private var lineBuffer: [String] = []
    private var lineWaiter: CheckedContinuation<String?, Never>?
    private var readError: String?
    private var didFinishReading = false
    private var nextID = 1
    private var auth: CodexAuth?
    private var accountId: String?

    func warmUpIfNeeded() async {
        guard let auth = try? CodexAuthReader.read(),
              auth.source == .authAccessToken,
              !auth.scopes.contains("api.responses.write") else {
            return
        }
        try? await startIfNeeded(auth: auth)
    }

    func metadata(for url: URL, page: PageSnapshot, context: BookmarkLibraryContext, auth: CodexAuth) async throws -> BookmarkMetadata {
        try await startIfNeeded(auth: auth)
        var latestText = ""
        var activeTurnID: String?

        let model = ProcessInfo.processInfo.environment["CLAWLICIOUS_OPENAI_MODEL"]
            ?? ProcessInfo.processInfo.environment["MARGINALIA_OPENAI_MODEL"]
            ?? ProcessInfo.processInfo.environment["COWRITER_OPENAI_MODEL"]
            ?? "gpt-5.5"
        let instructions = """
        Return only one JSON object with title, summary, tags, category, and contentWarning.
        tags must be 2-6 short lowercase strings.
        Prefer current categories and tags when they fit.
        Do not use tools or external app control; summarize only the page markdown provided below.
        If you cannot read the full bookmark content, set contentWarning to a concise user-facing explanation. Otherwise set contentWarning to null.
        Do not wrap the JSON in Markdown.
        """
        let inputText = """
        URL: \(url.absoluteString)
        Page title: \(page.title)
        Page description: \(page.description)
        Current categories: \(jsonList(context.categories))
        Current tags: \(jsonList(context.tags))
        Page markdown from the app browser:
        \(String(page.markdown.prefix(12_000)))
        """

        let thread = try await request("thread/start", [
            "model": model,
            "modelProvider": "openai",
            "cwd": FileManager.default.currentDirectoryPath,
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": "read-only",
            "personality": "none",
            "developerInstructions": instructions,
            "experimentalRawEvents": true,
            "persistExtendedHistory": false,
            "config": ["project_doc_max_bytes": 0]
        ])
        guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex app-server did not return a thread id."])
        }

        let turnID = nextID
        nextID += 1
        try write([
            "id": turnID,
            "method": "turn/start",
            "params": [
                "threadId": threadID,
                "input": [["type": "text", "text": inputText]],
                "cwd": FileManager.default.currentDirectoryPath,
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
                "model": model,
                "personality": "none",
                "effort": "none",
                "collaborationMode": [
                    "mode": "default",
                    "settings": [
                        "model": model,
                        "reasoning_effort": "none",
                        "developer_instructions": "Return only the bookmark metadata JSON object."
                    ]
                ]
            ]
        ])

        while true {
            let message = try await nextMessage()
            if let responseID = message["id"] as? Int, responseID == turnID {
                if let error = message["error"] as? [String: Any] {
                    throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex app-server turn failed."])
                }
                if let turn = (message["result"] as? [String: Any])?["turn"] as? [String: Any] {
                    activeTurnID = turn["id"] as? String
                }
                continue
            }
            guard let method = message["method"] as? String,
                  let params = message["params"] as? [String: Any],
                  params["threadId"] as? String == threadID else {
                continue
            }
            if let turnID = params["turnId"] as? String, let activeTurnID, turnID != activeTurnID {
                continue
            }
            if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
                latestText += delta
            } else if method == "item/completed",
                      let item = params["item"] as? [String: Any],
                      item["type"] as? String == "agentMessage",
                      let text = item["text"] as? String {
                latestText = text
            } else if method == "rawResponseItem/completed",
                      let item = params["item"] as? [String: Any],
                      item["role"] as? String == "assistant",
                      let text = readAssistantText(item["content"]) {
                latestText = text
            } else if method == "turn/completed" {
                let json = stripMarkdownFence(latestText)
                return try JSONDecoder().decode(BookmarkMetadata.self, from: Data(json.utf8))
            }
        }
    }

    private func startIfNeeded(auth: CodexAuth) async throws {
        guard auth.source == .authAccessToken, let accountId = auth.chatgptAccountId else {
            throw authError("This Codex credential cannot call the public Responses API, and it is not a ChatGPT OAuth credential Clawlicious can bridge through Codex app-server.")
        }
        if process?.isRunning == true, self.auth?.token == auth.token {
            return
        }
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [(ProcessInfo.processInfo.environment["CLAWLICIOUS_CODEX_COMMAND"] ?? "codex"), "app-server", "--listen", "stdio://"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "OPENAI_API_KEY": "",
            "CODEX_API_KEY": ""
        ]) { _, new in new }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        Task {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    enqueue(line)
                }
                finishReading()
            } catch {
                finishReading(error.localizedDescription)
            }
        }

        self.process = process
        input = stdin.fileHandleForWriting
        lineBuffer = []
        lineWaiter = nil
        readError = nil
        didFinishReading = false
        nextID = 1
        self.auth = auth
        self.accountId = accountId

        _ = try await request("initialize", [
            "clientInfo": ["name": "clawlicious", "title": "Clawlicious", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        try write(["method": "initialized"])
        _ = try await request("account/login/start", [
            "type": "chatgptAuthTokens",
            "accessToken": auth.token,
            "chatgptAccountId": accountId,
            "chatgptPlanType": auth.chatgptPlanType ?? NSNull()
        ])
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try write(["id": id, "method": method, "params": params])
        while true {
            let message = try await nextMessage()
            if let responseID = message["id"] as? Int, responseID == id {
                if let error = message["error"] as? [String: Any] {
                    throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex app-server request failed."])
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }

    private func nextMessage() async throws -> [String: Any] {
        while let line = try await nextLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let id = message["id"], let method = message["method"] as? String {
                try write(["id": id, "result": result(for: method)])
                continue
            }
            return message
        }
        stop()
        throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex app-server exited before completing bookmark metadata."])
    }

    private func enqueue(_ line: String) {
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(returning: line)
        } else {
            lineBuffer.append(line)
        }
    }

    private func finishReading(_ error: String? = nil) {
        readError = error
        didFinishReading = true
        lineWaiter?.resume(returning: nil)
        lineWaiter = nil
    }

    private func nextLine() async throws -> String? {
        if !lineBuffer.isEmpty {
            return lineBuffer.removeFirst()
        }
        if let readError {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: readError])
        }
        if didFinishReading {
            return nil
        }
        return await withCheckedContinuation { continuation in
            lineWaiter = continuation
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else {
            throw NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex app-server is not running."])
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        input.write(data)
        input.write(Data("\n".utf8))
    }

    private func result(for method: String) -> [String: Any] {
        switch method {
        case "account/chatgptAuthTokens/refresh":
            return [
                "accessToken": auth?.token ?? "",
                "chatgptAccountId": accountId ?? "",
                "chatgptPlanType": auth?.chatgptPlanType ?? NSNull()
            ]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return ["decision": "deny", "reason": "Clawlicious metadata turns cannot run commands or edit files that require approval."]
        case "item/tool/requestUserInput":
            return ["decision": "decline", "message": "No interactive input is available during bookmark metadata."]
        default:
            return [:]
        }
    }

    private func stop() {
        input = nil
        lineBuffer = []
        lineWaiter?.resume(returning: nil)
        lineWaiter = nil
        readError = nil
        didFinishReading = true
        process?.terminate()
        process = nil
        auth = nil
        accountId = nil
    }
}

private func responseText(_ data: Data) -> String? {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let text = body["output_text"] as? String { return text }
    guard let output = body["output"] as? [[String: Any]] else { return nil }
    for item in output {
        guard let content = item["content"] as? [[String: Any]] else { continue }
        for part in content {
            if let text = part["text"] as? String { return text }
        }
    }
    return nil
}

private func parseError(_ data: Data) -> String? {
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return String(data: data, encoding: .utf8)
    }
    if let error = body["error"] as? [String: Any], let message = error["message"] as? String {
        return message
    }
    return String(data: data, encoding: .utf8)
}

private func jsonList(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values),
          let text = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return text
}

private func authError(_ message: String) -> NSError {
    NSError(domain: "ClawliciousAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
}

private func readAssistantText(_ value: Any?) -> String? {
    guard let items = value as? [[String: Any]] else { return nil }
    let text = items.compactMap { $0["text"] as? String }.joined()
    return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func stripMarkdownFence(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("```") {
        value = value.replacing(/^```(?:json)?\s*/.ignoresCase(), with: "")
        value = value.replacing(/\s*```$/, with: "")
    }
    return value
}
