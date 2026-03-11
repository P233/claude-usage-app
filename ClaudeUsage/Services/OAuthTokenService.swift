import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "OAuthTokenService")

// MARK: - Protocol

protocol OAuthTokenServiceProtocol {
    /// Attempt to load OAuth credentials from Claude Code CLI's Keychain entry.
    /// Returns nil if Claude Code is not installed or has no stored credentials.
    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials?
}

// MARK: - Implementation

final class OAuthTokenService: OAuthTokenServiceProtocol {

    // MARK: - Keychain Reading

    /// Reads Claude Code credentials from Keychain using the `security` CLI.
    ///
    /// Uses `security find-generic-password` instead of `SecItemCopyMatching` because the CLI
    /// uses the legacy Keychain API which does not enforce per-app ACL checks. This avoids
    /// the recurring "wants to access your keychain" dialog that appears when Claude Code
    /// recreates the Keychain entry during token refresh (resetting the ACL).
    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", Constants.OAuth.claudeCodeKeychainService,
            "-a", NSUserName(),
            "-w"  // Output password data only
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run security command: \(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logger.debug("No Claude Code credentials found in Keychain")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard !data.isEmpty else {
            logger.debug("Empty Keychain entry for Claude Code")
            return nil
        }

        do {
            let credentials = try JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
            logger.info("Successfully loaded Claude Code credentials")
            return credentials
        } catch {
            logger.error("Failed to decode Claude Code credentials: \(error.localizedDescription)")
            return nil
        }
    }
}
