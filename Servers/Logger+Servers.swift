import os

// MARK: - Unified Logging

extension Logger {
    private nonisolated static let subsystem = "com.kirkouimet.Servers"

    /// App lifecycle: launch, signals, shutdown.
    nonisolated static let app = Logger(subsystem: subsystem, category: "App")

    /// The REST API listener.
    nonisolated static let serverApi = Logger(subsystem: subsystem, category: "ServerApi")

    /// Reading and writing `~/.servers/settings.json`, and the settings window.
    nonisolated static let settings = Logger(subsystem: subsystem, category: "Settings")
}
