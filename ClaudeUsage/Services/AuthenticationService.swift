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

    init(
        oauthTokenService: OAuthTokenServiceProtocol = OAuthTokenService()
    ) {
        self.oauthTokenService = oauthTokenService
    }

    // MARK: - Keychain Reading

    /// Reads OAuth tokens from Claude Code's Keychain entry.
    /// Returns nil if Claude Code is not installed or has no stored credentials.
    private func readTokensFromKeychain() -> OAuthTokens? {
        guard let credentials = oauthTokenService.loadClaudeCodeCredentials(),
              let tokens = credentials.claudeAiOauth else {
            return nil
        }
        return tokens
    }

    // MARK: - Credential Check

    func checkStoredCredentials() async {
        guard let tokens = readTokensFromKeychain() else {
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
        guard let tokens = readTokensFromKeychain() else {
            throw ClaudeAPIClient.APIError.notAuthenticated
        }

        guard !tokens.isExpired else {
            logger.info("OAuth: Keychain token expired, will retry on next cycle")
            throw ClaudeAPIClient.APIError.tokenExpired
        }

        return tokens.accessToken
    }

    // MARK: - Session Management

    /// Called when API returns 401/403 — session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        authState = .notAuthenticated
    }
}
