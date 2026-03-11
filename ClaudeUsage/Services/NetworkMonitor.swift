import Foundation
import Network
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "NetworkMonitor")

/// Monitors network connectivity status using NWPathMonitor.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// Whether the device currently has network connectivity
    @Published private(set) var isConnected: Bool = true

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.claudeusage.app.networkmonitor")

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                if wasConnected != self.isConnected {
                    if self.isConnected {
                        logger.info("Network connected")
                    } else {
                        logger.warning("Network disconnected")
                    }
                }
            }
        }

        monitor.start(queue: monitorQueue)
        logger.debug("Network monitoring started")
    }
}
