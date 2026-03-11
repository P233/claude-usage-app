import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "ClaudeAPIClient")

protocol ClaudeAPIClientProtocol {
    func fetchUsage() async throws -> UsageResponse
    func fetchPrepaidCredits() async throws -> PrepaidCredits
    func fetchOverageSpendLimit() async throws -> OverageSpendLimit
    func updateExtraUsage(enabled: Bool) async throws
}

final class ClaudeAPIClient: ClaudeAPIClientProtocol {

    enum APIError: Error, LocalizedError {
        case notAuthenticated
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int)
        case sessionExpired
        case tokenExpired
        case decodingError(Error)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not authenticated. Please log in."
            case .invalidURL:
                return "Invalid URL"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .sessionExpired:
                return "Session expired. Please log in again."
            case .tokenExpired:
                return "Token expired, waiting for refresh..."
            case .decodingError(let error):
                return "Failed to parse response: \(error.localizedDescription)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }

        /// Errors that should NOT be retried with exponential backoff.
        /// - Auth errors: session permanently invalid, requires re-login
        /// - Token expired: transient, will resolve when Claude Code refreshes; auto-refresh timer handles it
        var shouldSkipRetry: Bool {
            switch self {
            case .notAuthenticated, .sessionExpired, .tokenExpired:
                return true
            default:
                return false
            }
        }
    }

    private let authService: AuthenticationServiceProtocol
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(authService: AuthenticationServiceProtocol) {
        self.authService = authService

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.API.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Request Building

    private func makeOAuthRequest(for endpoint: String, method: String = "GET") async throws -> URLRequest {
        let accessToken = try await authService.getAccessToken()

        let url = Constants.OAuth.apiBaseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ClaudeCodeVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Constants.OAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    // MARK: - Response Handling

    private func handleResponse(_ response: URLResponse) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Handle 401/403 - session expired
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.warning("Session expired (HTTP \(httpResponse.statusCode))")
            await MainActor.run {
                authService.handleSessionExpired()
            }
            throw APIError.sessionExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error: \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        logger.debug("Request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

        do {
            let (data, response) = try await session.data(for: request)
            try await handleResponse(response)

            return try decoder.decode(T.self, from: data)

        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            logger.error("Decoding error: \(error.localizedDescription)")
            throw APIError.decodingError(error)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    private func performRequestWithoutResponse(_ request: URLRequest) async throws {
        logger.debug("Request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

        do {
            let (_, response) = try await session.data(for: request)
            try await handleResponse(response)
        } catch let error as APIError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    // MARK: - API Methods

    func fetchUsage() async throws -> UsageResponse {
        let request = try await makeOAuthRequest(for: "usage")
        return try await performRequest(request)
    }

    func fetchPrepaidCredits() async throws -> PrepaidCredits {
        let request = try await makeOAuthRequest(for: "prepaid/credits")
        return try await performRequest(request)
    }

    func fetchOverageSpendLimit() async throws -> OverageSpendLimit {
        let request = try await makeOAuthRequest(for: "overage_spend_limit")
        return try await performRequest(request)
    }

    func updateExtraUsage(enabled: Bool) async throws {
        var request = try await makeOAuthRequest(for: "overage_spend_limit", method: "PUT")
        request.httpBody = try JSONEncoder().encode(UpdateOverageSpendLimitRequest(isEnabled: enabled))
        try await performRequestWithoutResponse(request)
        logger.info("Extra usage updated: \(enabled)")
    }
}
