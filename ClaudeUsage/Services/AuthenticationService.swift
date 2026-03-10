import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AuthenticationService")

// MARK: - Protocol

@MainActor
protocol AuthenticationServiceProtocol: AnyObject {
    var authState: AuthState { get }
    var authStatePublisher: Published<AuthState>.Publisher { get }

    func checkStoredCredentials() async
    func getAccessToken() async throws -> String
    func handleSessionExpired()
}

// MARK: - Implementation

@MainActor
final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .unknown
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    private let oauthTokenService: OAuthTokenServiceProtocol

    /// In-memory OAuth token cache (read from Claude Code's Keychain, never written back).
    /// This app is a read-only consumer — it never refreshes tokens itself, because doing so
    /// would invalidate Claude Code's refresh token (server-side rotation) and force re-login.
    private var cachedOAuthTokens: OAuthTokens?

    init(
        oauthTokenService: OAuthTokenServiceProtocol = OAuthTokenService()
    ) {
        self.oauthTokenService = oauthTokenService
    }

    // MARK: - Credential Check

    func checkStoredCredentials() async {
        guard let credentials = oauthTokenService.loadClaudeCodeCredentials(),
              let oauthTokens = credentials.claudeAiOauth else {
            logger.info("No OAuth credentials found from Claude Code")
            authState = .notAuthenticated
            return
        }

        let subType = SubscriptionType.from(oauthSubscriptionType: oauthTokens.subscriptionType)
        let subscriptionType = subType.rawValue != nil
            ? subType
            : SubscriptionType.from(rateLimitTier: oauthTokens.rateLimitTier)

        // Even if the token is currently expired, credentials exist — treat as authenticated.
        // The auto-refresh cycle will re-read from Keychain when Claude Code refreshes the token.
        // Setting .notAuthenticated here would stop all timers and require manual reconnection.
        cachedOAuthTokens = oauthTokens
        if oauthTokens.isExpired {
            logger.info("OAuth: token expired, will retry on next refresh cycle")
        } else {
            logger.info("OAuth: authenticated via Claude Code credentials")
        }
        authState = .authenticated(subscriptionType: subscriptionType)
    }

    // MARK: - OAuth Access Token

    /// Returns a valid access token, re-reading from Keychain if the cached one has expired.
    /// Never refreshes tokens itself — only Claude Code should do that.
    func getAccessToken() async throws -> String {
        // Return cached token if still valid
        if let tokens = cachedOAuthTokens, !tokens.isExpired {
            return tokens.accessToken
        }

        // Token expired or not cached — re-read from Keychain (Claude Code may have refreshed)
        if let credentials = oauthTokenService.loadClaudeCodeCredentials(),
           let freshTokens = credentials.claudeAiOauth,
           !freshTokens.isExpired {
            cachedOAuthTokens = freshTokens
            logger.info("OAuth: using fresh token from Keychain")
            return freshTokens.accessToken
        }

        // Keychain token is also expired — wait for Claude Code to refresh it
        logger.info("OAuth: Keychain token expired, will retry on next cycle")
        cachedOAuthTokens = nil
        throw ClaudeAPIClient.APIError.tokenExpired
    }

    // MARK: - Session Management

    /// Called when API returns 401/403 — session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        cachedOAuthTokens = nil
        authState = .notAuthenticated
    }
}
