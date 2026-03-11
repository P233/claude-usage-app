import Foundation

// MARK: - Claude Code Keychain Credentials

/// Top-level JSON structure stored by Claude Code CLI in macOS Keychain.
/// Service: "Claude Code-credentials", Account: current username.
/// This app reads but never writes this Keychain entry.
struct ClaudeCodeCredentials: Codable {
    let claudeAiOauth: OAuthTokens?
    let organizationUuid: String?
}

/// OAuth token data from Claude Code CLI.
struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64 // milliseconds since epoch
    let scopes: [String]?
    let subscriptionType: String? // e.g., "max", "pro"
    let rateLimitTier: String? // e.g., "default_claude_max_5x"

    /// Whether the access token has expired (with 120-second safety margin).
    /// A larger margin reduces the chance of the token expiring mid-flight
    /// (between local check and server validation), which would cause a 401
    /// that triggers the retry-with-fresh-token flow unnecessarily.
    var isExpired: Bool {
        Date().addingTimeInterval(120) >= expirationDate
    }

    /// The Date when the access token expires.
    var expirationDate: Date {
        Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
    }
}
