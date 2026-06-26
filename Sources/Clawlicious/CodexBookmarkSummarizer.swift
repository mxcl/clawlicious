import Foundation

protocol BookmarkSummarizing: Sendable {
    func summarize(url: URL) async throws -> BookmarkMetadata
}

struct CodexBookmarkSummarizer: BookmarkSummarizing {
    func summarize(url: URL) async throws -> BookmarkMetadata {
        let page = try await PageFetcher.fetch(url)
        return try await CodexCLI().metadata(for: url, page: page)
    }
}

struct PageSnapshot: Sendable {
    var title: String
    var description: String
    var text: String
}

enum PageFetcher {
    static func fetch(_ url: URL) async throws -> PageSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Clawlicious/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw NSError(
                domain: "Clawlicious",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Could not fetch \(url.absoluteString): HTTP \(http.statusCode)."]
            )
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return PageSnapshot(
            title: firstMatch(in: html, #/<title[^>]*>(.*?)</title>/#) ?? url.bookmarkDomain,
            description: firstMatch(in: html, #/<meta\s+[^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*content=["']([^"']+)["'][^>]*>/#) ?? "",
            text: pageText(from: html)
        )
    }
}

private struct CodexCLI {
    func metadata(for url: URL, page: PageSnapshot) async throws -> BookmarkMetadata {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "clawlicious-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let schemaURL = temp.appending(path: "schema.json")
        let outputURL = temp.appending(path: "metadata.json")
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

        let prompt = """
        Summarize this bookmark for a local macOS bookmark library.

        Return only JSON matching the provided schema. Use 2-6 short lowercase tags.
        Pick one human category, for example: Development, Design, News, Reference, Tools, Writing, Video, Shopping, Other.

        URL: \(url.absoluteString)
        Page title: \(page.title)
        Page description: \(page.description)

        Page text:
        \(String(page.text.prefix(12_000)))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = temp
        process.arguments = [
            "codex",
            "--ask-for-approval", "never",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path,
            "-"
        ]

        let input = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardError = error
        process.standardOutput = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Clawlicious",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "Codex failed to summarize the bookmark." : stderr]
            )
        }

        let data = try Data(contentsOf: outputURL)
        return try JSONDecoder().decode(BookmarkMetadata.self, from: data)
    }

    private var schema: String {
        """
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "title": { "type": "string" },
            "summary": { "type": "string" },
            "tags": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 2,
              "maxItems": 6
            },
            "category": { "type": "string" }
          },
          "required": ["title", "summary", "tags", "category"]
        }
        """
    }
}

private func firstMatch(in html: String, _ regex: Regex<(Substring, Substring)>) -> String? {
    html.firstMatch(of: regex).map { match in
        String(match.1)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .htmlDecoded
    }
}

private func pageText(from html: String) -> String {
    html
        .replacing(#/<script[\s\S]*?</script>/#, with: " ")
        .replacing(#/<style[\s\S]*?</style>/#, with: " ")
        .replacing(#/<[^>]+>/#, with: " ")
        .replacing(/\s+/, with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .htmlDecoded
}

private extension String {
    var htmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
