import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "ActiveTasksService")

/// Monitors claude-code-switcher status files to count active Claude Code tasks.
/// Requires https://github.com/P233/claude-code-switcher to be set up.
/// If the status directory doesn't exist, the feature is disabled (returns nil).
///
/// Uses FSEvents to watch /tmp/cc-status/ for ANY file change (create, modify, delete).
/// Unlike kqueue/DispatchSource, FSEvents fires for in-place content changes too.
/// If the directory doesn't exist at startup, call `checkAndActivate()` periodically
/// (e.g. on each usage refresh) to detect late appearance.
@MainActor
final class ActiveTasksService: ObservableObject {
    @Published private(set) var activeTaskCount: Int?

    /// Resolved real path — /tmp is a symlink to /private/tmp on macOS,
    /// and FSEvents requires the canonical path to fire events reliably.
    private let statusDirectory: String = {
        URL(fileURLWithPath: "/tmp/cc-status").resolvingSymlinksInPath().path
    }()
    private let ideLocksDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/ide"
    }()
    private let fileManager = FileManager.default

    private var eventStream: FSEventStreamRef?
    /// Retains self while FSEventStream is active (balanced in stopEventStream)
    private var retainedSelf: Unmanaged<ActiveTasksService>?

    // MARK: - Lifecycle

    func start() {
        logger.info("ActiveTasksService watching: \(self.statusDirectory)")
        updateCount()
        startWatching()
    }

    func stop() {
        stopEventStream()
    }

    /// Called on each usage refresh cycle to detect late directory appearance.
    func checkAndActivate() {
        guard eventStream == nil,
              fileManager.fileExists(atPath: statusDirectory) else { return }
        startEventStream()
        updateCount()
    }

    // MARK: - FSEvents Monitoring

    private func startWatching() {
        guard fileManager.fileExists(atPath: statusDirectory) else { return }
        startEventStream()
    }

    private func startEventStream() {
        let pathsToWatch = [statusDirectory] as CFArray

        // passRetained keeps self alive while the stream's C callback holds the pointer.
        // Balanced by release() in stopEventStream.
        let retained = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, _, _, _ in
            guard let info else { return }
            let service = Unmanaged<ActiveTasksService>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                service.updateCount()
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer    // Fire immediately, don't wait for coalescing
        )

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventsGetCurrentEventId(),
            0.1, // 100ms coalescing latency
            flags
        ) else {
            logger.error("Failed to create FSEventStream")
            retained.release()
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream
        retainedSelf = retained
    }

    private func stopEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
        retainedSelf?.release()
        retainedSelf = nil
    }

    // MARK: - Core Logic

    private func updateCount() {
        guard fileManager.fileExists(atPath: statusDirectory) else {
            if activeTaskCount != nil {
                activeTaskCount = nil
            }
            return
        }

        let liveWorkspaces = loadLiveWorkspaces()
        let newCount = countRunningTasks(liveWorkspaces: liveWorkspaces)
        if activeTaskCount != newCount {
            activeTaskCount = newCount
        }
    }

    /// Reads IDE lock files and returns workspace folders with live PIDs.
    private func loadLiveWorkspaces() -> Set<String> {
        guard let files = try? fileManager.contentsOfDirectory(atPath: ideLocksDirectory) else {
            return []
        }

        var workspaces = Set<String>()

        for file in files where file.hasSuffix(".lock") {
            let path = "\(ideLocksDirectory)/\(file)"
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int else {
                continue
            }

            guard kill(pid_t(pid), 0) == 0 else { continue }

            if let folders = json["workspaceFolders"] as? [String] {
                for folder in folders {
                    workspaces.insert(folder)
                }
            }
        }

        return workspaces
    }

    /// Counts status files with "running" status that have a matching live IDE session.
    private func countRunningTasks(liveWorkspaces: Set<String>) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(atPath: statusDirectory) else {
            return 0
        }

        var count = 0

        for file in files where file.hasSuffix(".json") {
            let path = "\(statusDirectory)/\(file)"
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "running",
                  let cwd = json["cwd"] as? String else {
                continue
            }

            if liveWorkspaces.isEmpty || liveWorkspaces.contains(cwd) {
                count += 1
            }
        }

        return count
    }
}
