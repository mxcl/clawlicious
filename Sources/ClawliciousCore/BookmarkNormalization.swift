import Foundation

public func normalizedBookmarkURL(_ raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    let candidate = raw.contains("://") ? raw : "https://\(raw)"
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme), url.host != nil else {
        return nil
    }
    return url
}

public func normalizeTags(_ values: [String]) -> [String] {
    sortedUnique(values.map(normalizeTag).filter { !$0.isEmpty })
}

private func normalizeTag(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacing(/[^a-z0-9]+/, with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

public func normalizeCategory(_ value: String) -> String {
    let category = value.cleanedSingleLine
    return category.isEmpty ? "Uncategorized" : category.localizedCapitalized
}

public func sortedUnique(_ values: [String]) -> [String] {
    Array(Set(values)).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
}
