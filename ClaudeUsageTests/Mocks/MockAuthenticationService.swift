import Foundation
import Combine

/// Mock authentication service for testing UsageRefreshService
@MainActor
final class MockAuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .unknown
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    // MARK: - Test Control

    var mockAccessToken: String = "mock-access-token"

    func setAuthState(_ state: AuthState) {
        authState = state
    }

    // MARK: - AuthenticationServiceProtocol

    func checkStoredCredentials() async {
        // No-op for tests
    }

    func getAccessToken() async throws -> String {
        return mockAccessToken
    }

    func refreshAndGetAccessToken() async throws -> String {
        return mockAccessToken
    }

    func handleSessionExpired() {
        authState = .notAuthenticated
    }

    func setOverrideTokens(_ tokens: OAuthTokens?, subscriptionType: SubscriptionType) {
        // No-op for tests
    }

    func clearOverride() async {
        // No-op for tests
    }
}
