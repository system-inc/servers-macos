import Foundation
import Combine

extension Notification.Name {
    static let serverSettingsDidChange = Notification.Name("serverSettingsDidChange")
}

class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var serverStates: [String: ServerState] = [:]
    @Published var settings: ServerSettings?
    @Published var configError: String?
    @Published var appCpuUsage: Double = 0

    private var healthCheckTimers: [String: Timer] = [:]
    private var cpuMonitorTimer: Timer?
    // Main-thread only. A tick that lands while the last sample is still out skips, so a slow
    // ps can never stack up children behind it.
    private var cpuSampleInFlight = false

    private func nodeEnvPath(for projectPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = "\(home)/.nvm/versions/node"

        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir),
              !versions.isEmpty else {
            // No NVM — try Homebrew (Apple Silicon and Intel)
            for path in ["/opt/homebrew/bin", "/usr/local/bin"] {
                if FileManager.default.fileExists(atPath: "\(path)/node") {
                    return path
                }
            }
            return "/usr/local/bin:/usr/bin"
        }

        let nodeVersions = versions.filter { $0.hasPrefix("v") }

        // Try to match package.json engines.node
        if let wanted = readEngineNode(from: projectPath),
           nodeVersions.contains(wanted) {
            return "\(nvmDir)/\(wanted)/bin"
        }

        // Try .nvmrc
        if let nvmrc = try? String(contentsOfFile: "\(projectPath)/.nvmrc", encoding: .utf8) {
            let version = nvmrc.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixed = version.hasPrefix("v") ? version : "v\(version)"
            if nodeVersions.contains(prefixed) {
                return "\(nvmDir)/\(prefixed)/bin"
            }
        }

        // Fall back to latest installed version (semver sort)
        let sorted = nodeVersions.sorted { a, b in
            let partsA = a.dropFirst().split(separator: ".").compactMap { Int($0) }
            let partsB = b.dropFirst().split(separator: ".").compactMap { Int($0) }
            for i in 0..<min(partsA.count, partsB.count) {
                if partsA[i] != partsB[i] { return partsA[i] < partsB[i] }
            }
            return partsA.count < partsB.count
        }
        if let latest = sorted.last {
            return "\(nvmDir)/\(latest)/bin"
        }

        return "/usr/local/bin:/usr/bin"
    }

    private func readEngineNode(from projectPath: String) -> String? {
        let packageJsonPath = "\(projectPath)/package.json"
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engines = json["engines"] as? [String: String],
              let node = engines["node"] else {
            return nil
        }
        // Ensure it has the "v" prefix
        return node.hasPrefix("v") ? node : "v\(node)"
    }

    init() {
        if let loaded = ServerSettings.load() {
            self.settings = loaded
            setupServers()
        } else {
            self.configError = "Failed to load ~/.servers/settings.json"
        }
        startCpuMonitor()
    }

    private func setupServers() {
        guard let settings = settings else { return }
        for server in settings.servers {
            serverStates[server.id] = ServerState(server: server)
        }
    }

    // MARK: - CPU Monitoring

    private func startCpuMonitor() {
        cpuMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sampleCpuUsage()
        }
    }

    private func sampleCpuUsage() {
        guard !cpuSampleInFlight else { return }

        // Collect all PIDs we care about (running servers + self)
        var pidToServerId: [pid_t: String] = [:]
        for (id, state) in serverStates where state.pid > 0 && state.status == .running {
            pidToServerId[state.pid] = id
        }

        guard !pidToServerId.isEmpty else {
            // Still sample app CPU even with no servers running
            sampleAppCpu()
            return
        }

        // Use ps to get CPU for all processes, then sum by process tree
        cpuSampleInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // Get all processes with pid, ppid, %cpu. The table runs to tens of kilobytes on a
            // busy Mac, past the pipe buffer, which is why this goes through HelperCommand.
            guard let data = HelperCommand.output("/bin/ps", arguments: ["-eo", "pid,ppid,%cpu"]),
                  let output = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self.cpuSampleInFlight = false }
                return
            }

            // Parse ps output into (pid, ppid, cpu) tuples
            struct PsEntry {
                let pid: pid_t
                let ppid: pid_t
                let cpu: Double
            }

            var entries: [PsEntry] = []
            let appPid = ProcessInfo.processInfo.processIdentifier

            for line in output.components(separatedBy: "\n").dropFirst() {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard parts.count >= 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]),
                      let cpu = Double(parts[2]) else { continue }
                entries.append(PsEntry(pid: pid, ppid: ppid, cpu: cpu))
            }

            // Build parent -> children map
            var childrenOf: [pid_t: [pid_t]] = [:]
            var cpuOf: [pid_t: Double] = [:]
            for e in entries {
                childrenOf[e.ppid, default: []].append(e.pid)
                cpuOf[e.pid] = e.cpu
            }

            // Sum CPU for a process tree rooted at `root`
            func treeCpu(_ root: pid_t) -> Double {
                var total = cpuOf[root] ?? 0
                for child in childrenOf[root] ?? [] {
                    total += treeCpu(child)
                }
                return total
            }

            // Calculate per-server CPU
            var results: [String: Double] = [:]
            for (pid, serverId) in pidToServerId {
                results[serverId] = treeCpu(pid)
            }

            // App CPU (just this process, not its children which are the servers)
            let selfCpu = cpuOf[appPid] ?? 0

            DispatchQueue.main.async {
                self.cpuSampleInFlight = false
                for (serverId, cpu) in results {
                    self.serverStates[serverId]?.cpuUsage = cpu
                }
                // Zero out stopped servers
                for (_, state) in self.serverStates where state.status != .running {
                    state.cpuUsage = 0
                }
                self.appCpuUsage = selfCpu
                self.objectWillChange.send()
            }
        }
    }

    private func sampleAppCpu() {
        cpuSampleInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let appPid = ProcessInfo.processInfo.processIdentifier
            var cpu: Double?
            if let data = HelperCommand.output("/bin/ps", arguments: ["-p", "\(appPid)", "-o", "%cpu"]),
               let output = String(data: data, encoding: .utf8),
               let line = output.components(separatedBy: "\n").dropFirst().first {
                cpu = Double(line.trimmingCharacters(in: .whitespaces))
            }

            DispatchQueue.main.async {
                self?.cpuSampleInFlight = false
                if let cpu = cpu {
                    self?.appCpuUsage = cpu
                }
            }
        }
    }

    func reloadSettings() {
        guard let loaded = ServerSettings.load() else {
            configError = "Failed to load ~/.servers/settings.json"
            return
        }

        settings = loaded
        configError = nil

        // Find removed servers and stop them
        let newIds = Set(loaded.servers.map { $0.id })
        let oldIds = Set(serverStates.keys)
        for removedId in oldIds.subtracting(newIds) {
            stop(serverId: removedId)
            serverStates.removeValue(forKey: removedId)
        }

        // Add new servers
        for server in loaded.servers where serverStates[server.id] == nil {
            serverStates[server.id] = ServerState(server: server)
        }

        // Update existing server configs (preserve runtime state)
        for server in loaded.servers {
            if let existingState = serverStates[server.id] {
                // Update the server config on the state
                existingState.updateServer(server)
            }
        }

        // Notify observers
        objectWillChange.send()
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)
    }

    // MARK: - Server Control

    func start(serverId: String) {
        guard let state = serverStates[serverId] else { return }
        guard state.process == nil || state.process?.isRunning == false else {
            state.status = .running
            return
        }

        // Clear cooldown if manually started during cooldown window
        if state.inCooldown {
            state.inCooldown = false
            state.crashTimes.removeAll()
            state.appendLog("[system] Cooldown cleared - manual start")
        }

        state.stoppingIntentionally = false
        state.status = .starting
        state.lastError = nil

        // Kill any orphaned processes
        killExistingProcesses(for: state.server)

        // Kill anything still holding the target port
        if let port = state.server.port {
            let killed = killProcessesOnPort(port)
            if !killed.isEmpty {
                state.appendLog("[system] Killed \(killed.count) process(es) holding port \(port): PIDs \(killed.map { String($0) }.joined(separator: ", "))")
            }
        }

        // Remove stale lock files for Next.js
        let lockPath = state.server.expandedPath + "/.next/dev/lock"
        try? FileManager.default.removeItem(atPath: lockPath)

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: state.server.expandedPath)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")

        // Build command with proper PATH
        let nodePath = nodeEnvPath(for: state.server.expandedPath)
        let fullCommand = "export PATH=\(nodePath):$PATH && exec \(state.server.command)"
        process.arguments = ["-c", fullCommand]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodePath):" + (env["PATH"] ?? "")
        env["FORCE_COLOR"] = "1"  // Keep colors in output
        process.environment = env

        // Setup pipes for stdout/stderr capture
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout in background
        readPipeAsync(pipe: stdoutPipe, state: state, prefix: "")

        // Read stderr in background
        readPipeAsync(pipe: stderrPipe, state: state, prefix: "[stderr] ")

        process.terminationHandler = { [weak self, weak state] proc in
            DispatchQueue.main.async {
                guard let self = self, let state = state else { return }

                let exitCode = proc.terminationStatus
                state.appendLog("[system] Process exited with code \(exitCode)")

                if state.stoppingIntentionally {
                    state.stoppingIntentionally = false
                    state.status = .stopped
                } else if exitCode != 0 {
                    state.status = .crashed
                    state.lastError = "Exit code: \(exitCode)"
                    self.handleCrash(state: state)
                } else {
                    state.status = .stopped
                }

                state.isHealthy = false
            }
        }

        do {
            try process.run()
            state.process = process
            state.pid = process.processIdentifier
            state.status = .running
            state.appendLog("[system] Started with PID \(process.processIdentifier)")

            // Start health checks if port is configured
            startHealthCheck(for: state)

        } catch {
            state.status = .crashed
            state.lastError = error.localizedDescription
            state.appendLog("[system] Failed to start: \(error.localizedDescription)")
        }
    }

    func stop(serverId: String) {
        guard let state = serverStates[serverId] else { return }

        stopHealthCheck(for: state)

        // Mark as intentional so terminationHandler doesn't treat it as a crash
        state.stoppingIntentionally = true

        // Cancel cooldown
        state.inCooldown = false
        state.crashTimes.removeAll()

        if state.pid > 0 {
            // Kill the process group
            kill(-state.pid, SIGTERM)

            // Give it a moment to terminate gracefully
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if state.process?.isRunning == true {
                    kill(-state.pid, SIGKILL)
                }
            }
        }

        state.process?.terminate()
        state.process = nil
        state.pid = 0
        state.status = .stopped
        state.isHealthy = false
        state.appendLog("[system] Stopped")

        // Kill any orphaned processes
        killExistingProcesses(for: state.server)
    }

    func restart(serverId: String) {
        guard let state = serverStates[serverId] else { return }

        // Reset crash tracking on manual restart
        state.inCooldown = false
        state.crashTimes.removeAll()

        state.appendLog("[system] Restarting...")
        stop(serverId: serverId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(serverId: serverId)
        }
    }

    func startAll() {
        for id in serverStates.keys {
            start(serverId: id)
        }
    }

    func stopAll() {
        for id in serverStates.keys {
            stop(serverId: id)
        }
    }

    /// Synchronously force-kill all server processes. Use when quitting app.
    func forceStopAll() {
        // Collect all ports first
        var portsToKill: [Int] = []

        for (_, state) in serverStates {
            // Kill process group immediately
            if state.pid > 0 {
                kill(-state.pid, SIGKILL)
            }
            state.process?.terminate()

            if let port = state.server.port {
                portsToKill.append(port)
            }

            state.process = nil
            state.pid = 0
            state.status = .stopped
        }

        // Delay for SIGKILL to propagate
        Thread.sleep(forTimeInterval: 0.5)

        // Kill any remaining processes on ports using direct PIDs
        for port in portsToKill {
            killProcessesOnPort(port)
        }

        // Delay to ensure ports are released
        Thread.sleep(forTimeInterval: 1.0)
    }

    @discardableResult
    private func killProcessesOnPort(_ port: Int) -> [Int32] {
        // Get PIDs using lsof synchronously. No output (nothing on the port, or lsof failed) is fine.
        guard let data = HelperCommand.output("/usr/sbin/lsof", arguments: ["-ti", ":\(port)"]),
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        // Parse PIDs and kill each one directly
        let pids = output.components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        for pid in pids {
            kill(pid, SIGKILL)
        }
        return pids
    }

    // MARK: - Log Access

    func getLogs(serverId: String, lines: Int = 100) -> [String] {
        return serverStates[serverId]?.getLogs(lines: lines) ?? []
    }

    func clearLogs(serverId: String) {
        serverStates[serverId]?.clearLogs()
    }

    func getServerInfo(serverId: String) -> ServerInfo? {
        guard let state = serverStates[serverId] else { return nil }
        return ServerInfo(
            id: state.server.id,
            name: state.server.name,
            status: state.status.rawValue,
            isHealthy: state.isHealthy,
            port: state.server.port,
            lastError: state.lastError,
            cpuUsage: state.status == .running ? state.cpuUsage : nil
        )
    }

    func getAllServerInfo() -> [ServerInfo] {
        guard let settings = settings else { return [] }
        return settings.servers.compactMap { getServerInfo(serverId: $0.id) }
    }

    // MARK: - Private Helpers

    private func readPipeAsync(pipe: Pipe, state: ServerState, prefix: String) {
        let handle = pipe.fileHandleForReading

        DispatchQueue.global(qos: .background).async {
            var buffer = Data()

            while true {
                let data = handle.availableData
                if data.isEmpty { break }

                buffer.append(data)

                // Process complete lines
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[..<newlineIndex]
                    buffer = buffer[(newlineIndex + 1)...]

                    if let line = String(data: lineData, encoding: .utf8) {
                        let cleanLine = self.stripAnsiCodes(line)
                        DispatchQueue.main.async {
                            state.appendLog(prefix + cleanLine)
                        }
                    }
                }
            }

            // Handle any remaining data without newline
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                let cleanLine = self.stripAnsiCodes(line)
                DispatchQueue.main.async {
                    state.appendLog(prefix + cleanLine)
                }
            }
        }
    }

    private func stripAnsiCodes(_ string: String) -> String {
        // Remove ANSI escape codes for cleaner logs
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        return string.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private func killExistingProcesses(for server: Server) {
        // Use full command with word boundary to avoid killing sibling servers sharing the same path
        // e.g. "pnpm structure dev" must not match "pnpm structure dev land"
        let escapedCommand = NSRegularExpression.escapedPattern(for: server.command)
        let escapedPath = NSRegularExpression.escapedPattern(for: server.expandedPath)
        let pattern = "\(escapedPath).*\(escapedCommand)(\\s|$)"

        // No matching process is fine (pkill exits 1); nil means it couldn't launch or hung
        guard HelperCommand.output("/usr/bin/pkill", arguments: ["-9", "-f", pattern]) != nil else { return }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func handleCrash(state: ServerState) {
        let now = Date()
        state.crashTimes.append(now)
        state.crashTimes = state.crashTimes.filter {
            now.timeIntervalSince($0) < state.crashWindowSeconds
        }

        if state.crashTimes.count >= state.maxCrashesBeforeCooldown {
            state.inCooldown = true
            state.status = .cooldown
            state.appendLog("[system] Too many crashes - cooldown for \(Int(state.cooldownSeconds/60)) minutes")

            DispatchQueue.main.asyncAfter(deadline: .now() + state.cooldownSeconds) { [weak self, weak state] in
                guard let self = self, let state = state else { return }
                // Skip if cooldown was already cleared by a manual start
                guard state.inCooldown else { return }
                state.inCooldown = false
                state.crashTimes.removeAll()
                state.appendLog("[system] Cooldown ended - restarting")
                self.start(serverId: state.server.id)
            }
            return
        }

        state.appendLog("[system] Crashed - restarting (\(state.crashTimes.count)/\(state.maxCrashesBeforeCooldown))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak state] in
            guard let self = self, let state = state, !state.inCooldown else { return }
            self.start(serverId: state.server.id)
        }
    }

    // MARK: - Health Checks

    private func startHealthCheck(for state: ServerState) {
        guard let port = state.server.port else { return }

        stopHealthCheck(for: state)

        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak state] _ in
            guard let state = state else { return }
            self?.checkHealth(state: state, port: port)
        }

        healthCheckTimers[state.server.id] = timer

        // Initial check after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak state] in
            guard let state = state else { return }
            self?.checkHealth(state: state, port: port)
        }
    }

    private func stopHealthCheck(for state: ServerState) {
        healthCheckTimers[state.server.id]?.invalidate()
        healthCheckTimers.removeValue(forKey: state.server.id)
    }

    private func checkHealth(state: ServerState, port: Int) {
        // Use TCP socket check instead of HTTP to avoid polluting server logs
        // Resolves hostname to support both IPv4 and IPv6
        let hostname = state.server.hostname

        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC  // Allow both IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, String(port), &hints, &result)

            guard status == 0, let addrInfo = result else {
                DispatchQueue.main.async { state.isHealthy = false }
                return
            }
            defer { freeaddrinfo(result) }

            // Try each resolved address until one connects
            var info: UnsafeMutablePointer<addrinfo>? = addrInfo
            var connected = false

            while let ai = info {
                let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                if sock >= 0 {
                    // Set socket timeout
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    if connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                        connected = true
                        close(sock)
                        break
                    }
                    close(sock)
                }
                info = ai.pointee.ai_next
            }

            DispatchQueue.main.async {
                state.isHealthy = connected
            }
        }
    }
}

// MARK: - SSL Delegate for self-signed certs

class InsecureSSLDelegate: NSObject, URLSessionDelegate {
    static let shared = InsecureSSLDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
