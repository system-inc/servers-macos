import Foundation
import Network
import os

class ServerApi {
    private var listener: NWListener?
    private let manager: ServerManager
    private let port: UInt16

    init(manager: ServerManager, port: UInt16 = 7378) {
        self.manager = manager
        self.port = port
    }

    func start() {
        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            Logger.serverApi.error("Port \(self.port) is not a port a listener can bind")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: listenerPort)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                    case .ready:
                        Logger.serverApi.info("Listening on port \(self?.port ?? 0)")
                    case .failed(let error):
                        Logger.serverApi.error("Listener failed: \(error, privacy: .public)")
                    default:
                        break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                // The listener was started on the main queue, so it delivers connections there.
                MainActor.assumeIsolated {
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)
        }
        catch {
            Logger.serverApi.error("Failed to start: \(error, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            // The connection was started on the main queue, so it completes receives there.
            MainActor.assumeIsolated {
                guard let self, let data, error == nil else {
                    connection.cancel()
                    return
                }

                guard let request = String(data: data, encoding: .utf8) else {
                    self.sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
                    return
                }

                self.routeRequest(request: request, connection: connection)
            }
        }
    }

    private func routeRequest(request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let method = parts[0]
        let fullPath = parts[1]

        // Parse path and query string
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]
        let queryString = pathComponents.count > 1 ? pathComponents[1] : ""
        let query = parseQueryString(queryString)

        // Route the request
        switch (method, path) {

            // `GET /stats`: CPU usage for all servers and the app
            case ("GET", "/stats"):
                let stats = StatsResponse(
                    app: AppStats(cpuUsage: manager.appCpuUsage, pid: Int(ProcessInfo.processInfo.processIdentifier)),
                    servers: manager.getAllServerInfo(),
                )
                sendResponse(connection: connection, status: 200, body: stats)

            // `GET /servers`: List all servers
            case ("GET", "/servers"):
                let servers = manager.getAllServerInfo()
                sendResponse(connection: connection, status: 200, body: ["servers": servers])

            // `GET /servers/:id`: Get single server info
            case ("GET", _)
            where path.hasPrefix("/servers/") && !path.contains("/logs") && !path.contains("/start")
                && !path.contains("/stop") && !path.contains("/restart"):
                let id = String(path.dropFirst("/servers/".count))
                if let info = manager.getServerInfo(serverId: id) {
                    sendResponse(connection: connection, status: 200, body: info)
                }
                else {
                    sendResponse(connection: connection, status: 404, body: ["error": "Server not found"])
                }

            // `GET /servers/:id/logs`: Get server logs
            case ("GET", _) where path.hasSuffix("/logs"):
                let id = extractServerId(from: path, suffix: "/logs")
                let lines = Int(query["lines"] ?? "100") ?? 100
                let logs = manager.getLogs(serverId: id, lines: lines)
                let response = LogsResponse(
                    id: id,
                    lines: logs,
                    totalLines: manager.serverStates[id]?.logBuffer.count ?? 0,
                )
                sendResponse(connection: connection, status: 200, body: response)

            // `POST /servers/:id/start`: Start server
            case ("POST", _) where path.hasSuffix("/start"):
                let id = extractServerId(from: path, suffix: "/start")
                if manager.serverStates[id] != nil {
                    manager.start(serverId: id)
                    sendOutcome(.accepted(message: "Starting \(id)"), connection: connection)
                }
                else {
                    sendOutcome(.serverNotFound, connection: connection)
                }

            // `POST /servers/:id/stop`: Stop server
            case ("POST", _) where path.hasSuffix("/stop"):
                let id = extractServerId(from: path, suffix: "/stop")
                if manager.serverStates[id] != nil {
                    manager.stop(serverId: id)
                    sendOutcome(.accepted(message: "Stopping \(id)"), connection: connection)
                }
                else {
                    sendOutcome(.serverNotFound, connection: connection)
                }

            // `POST /servers/:id/restart`: Restart server
            case ("POST", _) where path.hasSuffix("/restart"):
                let id = extractServerId(from: path, suffix: "/restart")
                if manager.serverStates[id] != nil {
                    manager.restart(serverId: id)
                    sendOutcome(.accepted(message: "Restarting \(id)"), connection: connection)
                }
                else {
                    sendOutcome(.serverNotFound, connection: connection)
                }

            // `POST /servers/:id/clear-logs`: Clear logs
            case ("POST", _) where path.hasSuffix("/clear-logs"):
                let id = extractServerId(from: path, suffix: "/clear-logs")
                if manager.serverStates[id] != nil {
                    manager.clearLogs(serverId: id)
                    sendOutcome(.accepted(message: "Logs cleared"), connection: connection)
                }
                else {
                    sendOutcome(.serverNotFound, connection: connection)
                }

            // `POST /servers/start-all`
            case ("POST", "/servers/start-all"):
                manager.startAll()
                sendOutcome(.accepted(message: "Starting all servers"), connection: connection)

            // `POST /servers/stop-all`
            case ("POST", "/servers/stop-all"):
                manager.stopAll()
                sendOutcome(.accepted(message: "Stopping all servers"), connection: connection)

            // `POST /servers/reload-settings`
            case ("POST", "/servers/reload-settings"):
                manager.reloadSettings()
                sendOutcome(.accepted(message: "Settings reloaded"), connection: connection)

            default:
                sendResponse(connection: connection, status: 404, body: ["error": "Not found", "path": path])
        }
    }

    private func extractServerId(from path: String, suffix: String) -> String {
        var cleaned = path
        if cleaned.hasPrefix("/servers/") {
            cleaned = String(cleaned.dropFirst("/servers/".count))
        }
        if cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        return cleaned
    }

    private func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return result
    }

    private func sendOutcome(_ outcome: ActionOutcome, connection: NWConnection) {
        sendResponse(connection: connection, status: outcome.httpStatus, body: outcome)
    }

    private func sendResponse<T: Encodable>(connection: NWConnection, status: Int, body: T) {
        let statusText: String
        switch status {
            case 200: statusText = "OK"
            case 400: statusText = "Bad Request"
            case 404: statusText = "Not Found"
            case 500: statusText = "Internal Server Error"
            default: statusText = "Unknown"
        }

        var jsonData = Data()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            jsonData = try encoder.encode(body)
        }
        catch {
            jsonData = Data("{\"error\": \"JSON encoding failed\"}".utf8)
        }

        let response = """
            HTTP/1.1 \(status) \(statusText)\r
            Content-Type: application/json\r
            Content-Length: \(jsonData.count)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """

        var responseData = Data(response.utf8)
        responseData.append(jsonData)

        connection.send(
            content: responseData,
            completion: .contentProcessed { _ in
                connection.cancel()
            },
        )
    }
}
