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
    /// Refreshed tokens are only cached for this app's lifetime. On next launch, we re-read
    /// from Claude Code's Keychain (which Claude Code itself keeps fresh). This means a
    /// startup refresh network call is expected if the stored token has expired — acceptable
    /// tradeoff to avoid writing to another app's Keychain entry.
    private var cachedOAuthTokens: OAuthTokens?
    private var cachedRefreshToken: String?

    /// Coalesces concurrent token refresh requests to avoid duplicate network calls.
    private var activeRefreshTask: Task<String, Error>?

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

        cachedRefreshToken = oauthTokens.refreshToken

        if oauthTokens.isExpired {
            do {
                let refreshed = try await oauthTokenService.refreshAccessToken(refreshToken: oauthTokens.refreshToken)
                let expiresIn = refreshed.expiresIn ?? {
                    logger.warning("OAuth: server omitted expiresIn, defaulting to 3600s")
                    return 3600
                }()
                cachedOAuthTokens = OAuthTokens(
                    accessToken: refreshed.accessToken,
                    refreshToken: oauthTokens.refreshToken,
                    expiresAt: Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000),
                    scopes: oauthTokens.scopes,
                    subscriptionType: oauthTokens.subscriptionType,
                    rateLimitTier: oauthTokens.rateLimitTier
                )
                logger.info("OAuth: token refreshed successfully")
                authState = .authenticated(subscriptionType: subscriptionType)
            } catch {
                logger.warning("OAuth: token refresh failed: \(error.localizedDescription)")
                cachedOAuthTokens = nil
                cachedRefreshToken = nil
                authState = .notAuthenticated
            }
        } else {
            cachedOAuthTokens = oauthTokens
            logger.info("OAuth: authenticated via Claude Code credentials")
            authState = .authenticated(subscriptionType: subscriptionType)
        }
    }

    // MARK: - OAuth Access Token

    /// Returns a valid access token, refreshing if needed.
    /// Concurrent callers are coalesced into a single refresh request.
    func getAccessToken() async throws -> String {
        guard cachedOAuthTokens != nil else {
            throw ClaudeAPIClient.APIError.notAuthenticated
        }

        if let tokens = cachedOAuthTokens, !tokens.isExpired {
            return tokens.accessToken
        }

        // Token expired — re-read from Keychain (Claude Code may have refreshed)
        if let credentials = oauthTokenService.loadClaudeCodeCredentials(),
           let freshTokens = credentials.claudeAiOauth {
            if !freshTokens.isExpired {
                cachedOAuthTokens = freshTokens
                cachedRefreshToken = freshTokens.refreshToken
                logger.info("OAuth: using fresh token from Keychain")
                return freshTokens.accessToken
            }
            // Update cached tokens with latest from Keychain (refresh token may have rotated)
            cachedRefreshToken = freshTokens.refreshToken
            cachedOAuthTokens = freshTokens
        }

        // Coalesce concurrent refresh requests
        if let existing = activeRefreshTask {
            return try await existing.value
        }

        guard let refreshToken = cachedRefreshToken,
              let currentTokens = cachedOAuthTokens else {
            throw ClaudeAPIClient.APIError.sessionExpired
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw ClaudeAPIClient.APIError.sessionExpired }

            let refreshed = try await self.oauthTokenService.refreshAccessToken(refreshToken: refreshToken)
            let expiresIn = refreshed.expiresIn ?? {
                logger.warning("OAuth: server omitted expiresIn, defaulting to 3600s")
                return 3600
            }()

            let newRefreshToken = refreshed.refreshToken ?? refreshToken

            self.cachedOAuthTokens = OAuthTokens(
                accessToken: refreshed.accessToken,
                refreshToken: newRefreshToken,
                expiresAt: Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000),
                scopes: currentTokens.scopes,
                subscriptionType: currentTokens.subscriptionType,
                rateLimitTier: currentTokens.rateLimitTier
            )
            self.cachedRefreshToken = newRefreshToken

            logger.info("OAuth: access token refreshed on demand")
            return refreshed.accessToken
        }

        activeRefreshTask = task
        defer { activeRefreshTask = nil }
        return try await task.value
    }

    // MARK: - Session Management

    /// Called when API returns 401/403 — session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        cachedOAuthTokens = nil
        cachedRefreshToken = nil
        authState = .notAuthenticated
    }
}
