import ClawliciousCore

extension BookmarkCommandClient {
    static let clawlicious = BookmarkCommandClient { command in
        MenuBarHelperLauncher.launchIfNeeded()
        try await BookmarkCommandClient.loopback.send(command)
    }
}
