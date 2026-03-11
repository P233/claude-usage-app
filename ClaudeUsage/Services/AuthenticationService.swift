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
    func refreshAndGetAccessToken() async throws -> String
    func handleSessionExpired()
}

// MARK: - Implementation

@MainActor
final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .unknown
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    private let oauthTokenService: OAuthTokenServiceProtocol

    /// Cached Keychain read result to avoid repeated subprocess spawns within a refresh cycle.
    /// Multiple API calls (usage, credits, spend_limit) happen in quick succession — no need
    /// to fork `/usr/bin/security` for each one.
    private var cachedTokens: OAuthTokens?
    private var cachedTokensTimestamp: Date?
    private static let tokenCacheTTL: TimeInterval = 10 // seconds

    init(
        oauthTokenService: OAuthTokenServiceProtocol = OAuthTokenService()
    ) {
        self.oauthTokenService = oauthTokenService
    }

    // MARK: - Keychain Reading

    /// Reads OAuth tokens from Claude Code's Keychain entry, using a short-lived cache
    /// to avoid spawning repeated `/usr/bin/security` subprocesses within the same refresh cycle.
    private func readTokensFromKeychain(bypassCache: Bool = false) async -> OAuthTokens? {
        // Return cached result if still fresh
        if !bypassCache,
           let cached = cachedTokens,
           let timestamp = cachedTokensTimestamp,
           Date().timeIntervalSince(timestamp) < Self.tokenCacheTTL {
            return cached
        }

        guard let credentials = await oauthTokenService.loadClaudeCodeCredentials(),
              let tokens = credentials.claudeAiOauth else {
            cachedTokens = nil
            cachedTokensTimestamp = nil
            return nil
        }

        cachedTokens = tokens
        cachedTokensTimestamp = Date()
        return tokens
    }

    // MARK: - Credential Check

    func checkStoredCredentials() async {
        guard let tokens = await readTokensFromKeychain() else {
            logger.info("No OAuth credentials found from Claude Code")
            authState = .notAuthenticated
            return
        }

        let subType = SubscriptionType.from(oauthSubscriptionType: tokens.subscriptionType)
        let subscriptionType = subType.rawValue != nil
            ? subType
            : SubscriptionType.from(rateLimitTier: tokens.rateLimitTier)

        // Even if the token is currently expired, credentials exist — treat as authenticated.
        // The auto-refresh cycle will re-read from Keychain when Claude Code refreshes the token.
        if tokens.isExpired {
            logger.info("OAuth: token expired, will retry on next refresh cycle")
        } else {
            logger.info("OAuth: authenticated via Claude Code credentials")
        }
        authState = .authenticated(subscriptionType: subscriptionType)
    }

    // MARK: - OAuth Access Token

    /// Returns a valid access token by reading directly from Keychain.
    /// This app is a read-only consumer — it never refreshes tokens itself.
    func getAccessToken() async throws -> String {
        guard let tokens = await readTokensFromKeychain() else {
            throw ClaudeAPIClient.APIError.notAuthenticated
        }

        guard !tokens.isExpired else {
            logger.info("OAuth: Keychain token expired, will retry on next cycle")
            throw ClaudeAPIClient.APIError.tokenExpired
        }

        return tokens.accessToken
    }

    /// Re-reads Keychain for a fresh token after a 401 response.
    /// Claude Code may have refreshed the token since the last read.
    /// Bypasses the token cache to ensure we get the latest from Keychain.
    func refreshAndGetAccessToken() async throws -> String {
        logger.info("OAuth: re-reading Keychain after 401 for fresh token")

        guard let tokens = await readTokensFromKeychain(bypassCache: true) else {
            throw ClaudeAPIClient.APIError.notAuthenticated
        }

        guard !tokens.isExpired else {
            logger.info("OAuth: Keychain token still expired after re-read")
            throw ClaudeAPIClient.APIError.tokenExpired
        }

        return tokens.accessToken
    }

    // MARK: - Session Management

    /// Called when API returns 401/403 — session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        cachedTokens = nil
        cachedTokensTimestamp = nil
        authState = .notAuthenticated
    }
}
