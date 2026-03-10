import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "ClaudeCodeVersion")

/// Detects and caches the locally installed Claude Code CLI version for User-Agent headers.
/// Call `refresh()` after system wake to pick up updates installed during sleep.
enum ClaudeCodeVersion {

    private static let fallback = "claude-code"

    /// Current User-Agent string. Lazily detected on first access.
    private(set) static var userAgent: String = detect()

    /// Re-detect the CLI version. Called on system wake.
    static func refresh() {
        let newValue = detect()
        if newValue != userAgent {
            logger.info("Claude Code version changed: \(userAgent) → \(newValue)")
            userAgent = newValue
        }
    }

    // MARK: - Private

    private static func detect() -> String {
        guard let url = locateBinary() else { return fallback }

        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return fallback
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        // "2.1.71 (Claude Code)" → "2.1.71"
        guard process.terminationStatus == 0,
              let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first,
              !version.isEmpty else {
            return fallback
        }

        return "claude-code/\(version)"
    }

    private static func locateBinary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSString("~/.claude/local/claude").expandingTildeInPath
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
