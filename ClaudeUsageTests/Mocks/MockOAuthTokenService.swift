import Foundation

/// Mock OAuth token service for testing
final class MockOAuthTokenService: OAuthTokenServiceProtocol {

    // MARK: - Configurable Behavior

    var credentials: ClaudeCodeCredentials?

    // MARK: - Call Tracking

    private(set) var loadCredentialsCallCount = 0

    // MARK: - OAuthTokenServiceProtocol

    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials? {
        loadCredentialsCallCount += 1
        return credentials
    }
}
