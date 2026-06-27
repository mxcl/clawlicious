import Foundation

public struct PageSnapshot: Sendable {
    public var title: String
    public var description: String
    public var markdown: String

    public init(title: String, description: String, markdown: String) {
        self.title = title
        self.description = description
        self.markdown = markdown
    }
}

public enum PageExtraction {
    public static func requireReadableMarkdown(_ snapshot: PageSnapshot) throws -> PageSnapshot {
        let text = clean(snapshot.markdown)
        guard !text.isEmpty else {
            throw NSError(domain: "Clawlicious", code: 2, userInfo: [NSLocalizedDescriptionKey: "No readable page text was captured."])
        }
        guard !isBrowserPlaceholder(text) else {
            throw NSError(domain: "Clawlicious", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only browser chrome was captured."])
        }
        return snapshot
    }

    public static func isReadable(_ snapshot: PageSnapshot) -> Bool {
        (try? requireReadableMarkdown(snapshot)) != nil
    }

    public static func clean(_ text: String) -> String {
        text.replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBrowserPlaceholder(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("to view keyboard shortcuts, press question mark")
            && text.localizedCaseInsensitiveContains("view keyboard shortcuts")
    }

    public static let markdownSnapshotScript = #"""
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
        if (tag === "IMG") {
          const src = node.currentSrc || node.getAttribute("src") || node.getAttribute("data-src");
          if (!src || src.startsWith("data:") || src.startsWith("blob:")) return "";
          const alt = esc(node.getAttribute("alt") || node.getAttribute("aria-label") || node.getAttribute("title") || "Image");
          try {
            return `![${alt}](${new URL(src, location.href).href})`;
          } catch {
            return "";
          }
        }
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
      const fallback = clean(document.body?.innerText || "");

      return {
        title: document.title || "",
        description: document.querySelector("meta[name=description], meta[property='og:description']")?.content || "",
        markdown: markdown.length >= 80 ? markdown : fallback
      };
    })();
    """#
}
