import Combine
import Foundation
import os

// MARK: - Server Model

struct Server: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let command: String
    let port: Int?
    let hostname: String
    let healthCheckPath: String?
    let https: Bool?
    let autoStart: Bool?
    let visible: Bool?

    var expandedPath: String {
        NSString(string: path).expandingTildeInPath
    }

    var useHttps: Bool {
        https ?? false
    }

    var shouldAutoStart: Bool {
        autoStart ?? false
    }

    var isVisible: Bool {
        visible ?? true
    }

    /// Where the server answers in a browser. Nil without a port, or when the hostname can't form a URL.
    var browserUrl: URL? {
        guard let port else { return nil }
        return URL(string: "\(useHttps ? "https" : "http")://\(hostname):\(port)")
    }

    init(
        id: String,
        name: String,
        path: String,
        command: String,
        port: Int? = nil,
        hostname: String,
        healthCheckPath: String? = nil,
        https: Bool? = nil,
        autoStart: Bool? = nil,
        visible: Bool? = nil,
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.command = command
        self.port = port
        self.hostname = hostname
        self.healthCheckPath = healthCheckPath ?? "/"
        self.https = https
        self.autoStart = autoStart
        self.visible = visible
    }
}

// MARK: - Server Status

enum ServerStatus: String, Codable {
    case stopped = "stopped"
    case starting = "starting"
    case running = "running"
    case crashed = "crashed"
    case cooldown = "cooldown"
}

// MARK: - Server State (Runtime)

class ServerState: ObservableObject {
    private(set) var server: Server
    @Published var status: ServerStatus = .stopped
    @Published var isHealthy: Bool = false
    @Published var lastError: String?

    var process: Process?
    var pid: pid_t = 0
    @Published var cpuUsage: Double = 0 // Total CPU % for process tree
    @Published var logBuffer: [String] = []
    @Published var logTimestamps: [Date] = []
    var crashTimes: [Date] = []

    let maximumLogLines = 5000
    let maximumCrashesBeforeCooldown = 3
    let crashWindowSeconds: TimeInterval = 60
    let cooldownSeconds: TimeInterval = 300
    var inCooldown = false
    var stoppingIntentionally = false

    init(server: Server) {
        self.server = server
    }

    func updateServer(_ newServer: Server) {
        self.server = newServer
        objectWillChange.send()
    }

    func appendLog(_ line: String) {
        logBuffer.append(line)
        logTimestamps.append(Date())
        if logBuffer.count > maximumLogLines {
            let overflow = logBuffer.count - maximumLogLines
            logBuffer.removeFirst(overflow)
            logTimestamps.removeFirst(overflow)
        }
    }

    func getLogs(lines: Int = 100) -> [String] {
        let count = min(lines, logBuffer.count)
        return Array(logBuffer.suffix(count))
    }

    func clearLogs() {
        logBuffer.removeAll()
        logTimestamps.removeAll()
    }
}

// MARK: - Config

struct ServerSettings: Codable {
    var servers: [Server]
    var apiPort: Int?

    var resolvedApiPort: Int {
        apiPort ?? 7378
    }

    static let defaultSettingsPath = "~/.servers/settings.json"

    static func load() -> ServerSettings? {
        let path = NSString(string: defaultSettingsPath).expandingTildeInPath

        guard let data = FileManager.default.contents(atPath: path) else {
            Logger.settings.error("No settings file found at \(path, privacy: .public)")
            return nil
        }

        do {
            return try JSONDecoder().decode(ServerSettings.self, from: data)
        }
        catch {
            Logger.settings.error("Failed to parse settings file: \(error, privacy: .public)")
            return nil
        }
    }

    func save() {
        let path = NSString(string: ServerSettings.defaultSettingsPath).expandingTildeInPath
        let directory = (path as NSString).deletingLastPathComponent

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try encoder.encode(self).write(to: URL(fileURLWithPath: path))
        }
        catch {
            // The settings window keeps its edits in memory, so a failed write loses nothing yet;
            // the reload that follows reads back what is on disk.
            Logger.settings.error("Failed to save settings to \(path, privacy: .public): \(error, privacy: .public)")
        }
    }
}

// MARK: - API Response Types

struct ServerListResponse: Codable {
    let servers: [ServerInfo]
}

struct ServerInfo: Codable {
    let id: String
    let name: String
    let status: String
    let isHealthy: Bool
    let port: Int?
    let lastError: String?
    let cpuUsage: Double?
}

struct LogsResponse: Codable {
    let id: String
    let lines: [String]
    let totalLines: Int
}

/// How a control request (start, stop, restart, clear logs, reload) turned out.
///
/// On the wire it is `{"message": String, "success": Bool}`, the shape agents and scripts read.
enum ActionOutcome: Encodable {
    case accepted(message: String)
    case serverNotFound

    var httpStatus: Int {
        switch self {
            case .accepted: 200
            case .serverNotFound: 404
        }
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case message
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .accepted(let message):
                try container.encode(true, forKey: .success)
                try container.encode(message, forKey: .message)
            case .serverNotFound:
                try container.encode(false, forKey: .success)
                try container.encode("Server not found", forKey: .message)
        }
    }
}

struct AppStats: Codable {
    let cpuUsage: Double
    let pid: Int
}

struct StatsResponse: Codable {
    let app: AppStats
    let servers: [ServerInfo]
}
