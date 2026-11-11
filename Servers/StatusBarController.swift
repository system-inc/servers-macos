import AppKit
import Combine
import SwiftUI

class StatusBarController: ObservableObject {
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var cancellables = Set<AnyCancellable>()

    // Server management
    let serverManager = ServerManager.shared
    var serverApi: ServerApi?

    // Menu items we need to update dynamically
    private var serverLabelItems: [String: NSMenuItem] = [:]
    private var serverButtonItems: [String: NSMenuItem] = [:]
    private var settingsObserver: (any NSObjectProtocol)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        setupStatusBarButton()
        setupMenu()

        // Start the API server
        if let settings = serverManager.settings {
            serverApi = ServerApi(manager: serverManager, port: UInt16(settings.resolvedApiPort))
            serverApi?.start()

            // Auto-start servers with autoStart: true
            for server in settings.servers where server.shouldAutoStart {
                serverManager.start(serverId: server.id)
            }
        }

        // Subscribe to server state changes
        startObservingServers()

        // Subscribe to settings changes to rebuild menu
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .serverSettingsDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            // Registered on the main queue, so it's delivered there.
            MainActor.assumeIsolated {
                self?.rebuildMenu()
            }
        }
    }

    isolated deinit {
        serverApi?.stop()
        serverManager.forceStopAll()
    }

    private func setupStatusBarButton() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Servers")
            image?.isTemplate = true // Adapts to light/dark mode
            button.image = image
        }
        statusItem.menu = menu
    }

    private func setupMenu() {
        buildMenuItems()
    }

    private func buildMenuItems() {
        // Header
        let headerMenuItem = NSMenuItem()
        let headerView = NSHostingView(rootView: MenuHeaderView(serverManager: serverManager))
        headerView.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        headerMenuItem.view = headerView
        menu.addItem(headerMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Server items, only the visible ones
        if let settings = serverManager.settings {
            let visibleServers = settings.servers.filter { $0.isVisible }
            for server in visibleServers {
                let (labelItem, buttonItem) = createServerMenuItems(for: server)
                serverLabelItems[server.id] = labelItem
                serverButtonItems[server.id] = buttonItem
                menu.addItem(labelItem)
                menu.addItem(buttonItem)
                menu.addItem(NSMenuItem.separator())
            }
        }
        else if let error = serverManager.configurationError {
            let errorItem = NSMenuItem(title: "\(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Servers", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        serverLabelItems.removeAll()
        serverButtonItems.removeAll()
        cancellables.removeAll()
        buildMenuItems()
        startObservingServers()
    }

    private func createServerMenuItems(for server: Server) -> (NSMenuItem, NSMenuItem) {
        let state = serverManager.serverStates[server.id]
        let status = state?.status ?? .stopped

        // Row 1: Clickable label (a tap gesture inside the SwiftUI view), opens the log window
        let labelItem = NSMenuItem()
        let labelView = ServerLabelView(
            name: server.name,
            port: server.port.map { ":\($0)" } ?? "",
            status: status,
            cpuUsage: state?.cpuUsage,
            onTap: { [weak self] in
                self?.menu.cancelTracking()
                LogWindowController.show(serverId: server.id, manager: self?.serverManager ?? ServerManager.shared)
            },
        )
        let labelHosting = NSHostingView(rootView: labelView)
        labelHosting.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        labelItem.view = labelHosting

        // Row 2: Buttons
        let buttonItem = NSMenuItem()
        let apiPort = serverManager.settings?.resolvedApiPort ?? 7378
        let buttonsView = ServerControlButtons(
            status: status,
            onStart: { [weak self] in self?.serverManager.start(serverId: server.id) },
            onStop: { [weak self] in self?.serverManager.stop(serverId: server.id) },
            onRestart: { [weak self] in self?.serverManager.restart(serverId: server.id) },
            onOpenBrowser: server.port != nil
                ? { [weak self] in
                    self?.menu.cancelTracking()
                    if let url = server.browserUrl {
                        NSWorkspace.shared.open(url)
                    }
                } : nil,
            onCopyInstructions: {
                ServerInstructions.copyToClipboard(for: server, apiPort: apiPort)
            },
        )
        let wrappedButtons = buttonsView.padding(.horizontal, 14).padding(.vertical, 4).frame(
            width: 280,
            alignment: .leading,
        )
        let buttonHosting = NSHostingView(rootView: wrappedButtons)
        buttonHosting.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
        buttonItem.view = buttonHosting

        return (labelItem, buttonItem)
    }

    private func startObservingServers() {
        for (id, state) in serverManager.serverStates {
            state.$status
                .combineLatest(state.$isHealthy, state.$cpuUsage)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status, isHealthy, _ in
                    self?.updateServerMenuItem(id: id, status: status, isHealthy: isHealthy)
                }
                .store(in: &cancellables)
        }
    }

    private func updateServerMenuItem(id: String, status: ServerStatus, isHealthy: Bool) {
        guard let server = serverManager.settings?.servers.first(where: { $0.id == id }) else { return }
        let cpuUsage = serverManager.serverStates[id]?.cpuUsage

        // Update label
        if let labelItem = serverLabelItems[id] {
            let portSuffix = server.port.map { ":\($0)" } ?? ""
            let labelView = ServerLabelView(
                name: server.name,
                port: portSuffix,
                status: status,
                cpuUsage: cpuUsage,
                onTap: { [weak self] in
                    self?.menu.cancelTracking()
                    LogWindowController.show(serverId: server.id, manager: self?.serverManager ?? ServerManager.shared)
                },
            )
            let hosting = NSHostingView(rootView: labelView)
            hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
            labelItem.view = hosting
        }

        // Update buttons
        if let buttonItem = serverButtonItems[id] {
            let apiPort = serverManager.settings?.resolvedApiPort ?? 7378
            let buttonsView = ServerControlButtons(
                status: status,
                onStart: { [weak self] in self?.serverManager.start(serverId: server.id) },
                onStop: { [weak self] in self?.serverManager.stop(serverId: server.id) },
                onRestart: { [weak self] in self?.serverManager.restart(serverId: server.id) },
                onOpenBrowser: server.port != nil
                    ? { [weak self] in
                        self?.menu.cancelTracking()
                        if let url = server.browserUrl {
                            NSWorkspace.shared.open(url)
                        }
                    } : nil,
                onCopyInstructions: {
                    ServerInstructions.copyToClipboard(for: server, apiPort: apiPort)
                },
            )
            let wrappedButtons = buttonsView.padding(.horizontal, 14).padding(.vertical, 4).frame(
                width: 280,
                alignment: .leading,
            )
            let hosting = NSHostingView(rootView: wrappedButtons)
            hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
            buttonItem.view = hosting
        }
    }

    // MARK: - Actions

    @objc func openSettings() {
        SettingsWindowController.show()
    }

    @objc func quitApp() {
        serverManager.forceStopAll()
        serverApi?.stop()
        // Give processes time to fully terminate and release ports
        Thread.sleep(forTimeInterval: 2.0)
        NSApp.terminate(nil)
    }
}

// MARK: - Menu Header View

struct MenuHeaderView: View {
    @ObservedObject var serverManager: ServerManager

    var body: some View {
        HStack {
            Text("Servers")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            let cpu = serverManager.appCpuUsage
            if cpu > 50 {
                HStack(spacing: 2) {
                    Text("App")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(CpuPercentText.whole(cpu))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(cpu > 100 ? .red : .orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(width: 280)
    }
}

// MARK: - Server Instructions Generator

enum ServerInstructions {
    static func markdown(for server: Server, apiPort: Int = 7378) -> String {
        let url = server.browserUrl?.absoluteString
        let base = "http://localhost:\(apiPort)"
        let serverEndpoint = "\(base)/servers/\(server.id)"

        var instructions = "# \(server.name)\n\n"
        instructions += "Managed by **Servers.app**, a macOS menubar app for local dev servers. "
        instructions += "All servers can be controlled via a REST API on port \(apiPort).\n\n"

        if let url {
            instructions += "**URL:** \(url)\n"
        }
        instructions += "**Path:** `\(server.path)`\n"

        instructions += """

            ```bash
            curl \(serverEndpoint)                  # status
            curl \(serverEndpoint)/logs?lines=200   # logs
            curl -X POST \(serverEndpoint)/start    # start
            curl -X POST \(serverEndpoint)/stop     # stop
            curl -X POST \(serverEndpoint)/restart  # restart
            curl \(base)/servers              # all servers
            ```
            """

        return instructions
    }

    static func copyToClipboard(for server: Server, apiPort: Int = 7378) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(for: server, apiPort: apiPort), forType: .string)
    }
}

// MARK: - Server Control Buttons (reused in menu and log window)

struct ServerControlButtons: View {
    let status: ServerStatus
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    var onOpenBrowser: (() -> Void)? = nil
    var onCopyInstructions: (() -> Void)? = nil
    var size: ActionButton.Size = .small

    @State private var showCopied = false

    private var canStart: Bool {
        status == .stopped || status == .crashed
    }

    private var canStop: Bool {
        status == .running || status == .starting
    }

    var body: some View {
        HStack(spacing: 6) {
            if canStart {
                ActionButton(icon: "play.fill", color: .green, enabled: true, size: size, tooltip: "Start") {
                    onStart()
                }
            }
            else {
                ActionButton(icon: "stop.fill", color: .red, enabled: true, size: size, tooltip: "Stop") {
                    onStop()
                }
            }

            ActionButton(icon: "arrow.clockwise", color: .blue, enabled: canStop, size: size, tooltip: "Restart") {
                onRestart()
            }

            if let onCopyInstructions = onCopyInstructions {
                ActionButton(
                    icon: showCopied ? "checkmark" : "text.book.closed",
                    color: showCopied ? .green : .purple,
                    enabled: true,
                    size: size,
                    tooltip: "Copy Instructions",
                ) {
                    onCopyInstructions()
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                }
            }

            if let onOpenBrowser = onOpenBrowser {
                ActionButton(icon: "safari", color: .cyan, enabled: true, size: size, tooltip: "Open in Browser") {
                    onOpenBrowser()
                }
            }
        }
    }
}

// MARK: - Server Label View (clickable row)

struct ServerLabelView: View {
    let name: String
    let port: String
    let status: ServerStatus
    var cpuUsage: Double? = nil
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            if let cpu = cpuUsage, status == .running, cpu > 50 {
                Text(CpuPercentText.adaptive(cpu))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(cpuColor(cpu))
            }

            Spacer()

            if !port.isEmpty {
                Text(port)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(status == .running ? .green : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: 280, height: 26)
        .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onTap?() }
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu > 100 { return .red }
        if cpu > 50 { return .orange }
        return .secondary
    }
}

// MARK: - CPU Percent Text

enum CpuPercentText {
    /// Whole percent, as in "142%".
    static func whole(_ cpu: Double) -> String {
        text(cpu, fractionDigits: 0)
    }

    /// One decimal under 10%, whole above, as in "3.5%" and "142%".
    static func adaptive(_ cpu: Double) -> String {
        text(cpu, fractionDigits: cpu < 10 ? 1 : 0)
    }

    private static func text(_ cpu: Double, fractionDigits: Int) -> String {
        cpu.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never)) + "%"
    }
}

// MARK: - Action Button

struct ActionButton: View {
    enum Size {
        case small, medium

        var iconSize: CGFloat {
            switch self {
                case .small: return 11
                case .medium: return 13
            }
        }

        var frameWidth: CGFloat {
            switch self {
                case .small: return 28
                case .medium: return 32
            }
        }

        var frameHeight: CGFloat {
            switch self {
                case .small: return 22
                case .medium: return 26
            }
        }
    }

    let icon: String
    let color: Color
    let enabled: Bool
    var size: Size = .small
    var tooltip: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size.iconSize, weight: .medium))
            .foregroundStyle(enabled ? (isHovered ? .white : color) : .gray.opacity(0.4))
            .frame(width: size.frameWidth, height: size.frameHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                if enabled { isHovered = hovering }
            }
            .onTapGesture {
                guard enabled else { return }
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPressed = false
                    action()
                }
            }
            .help(tooltip ?? "")
    }

    private var backgroundColor: Color {
        guard enabled else { return .clear }
        if isPressed {
            return color.opacity(0.7)
        }
        else if isHovered {
            return color.opacity(0.6)
        }
        return color.opacity(0.1)
    }

    private var borderColor: Color {
        guard enabled else { return .gray.opacity(0.15) }
        if isHovered {
            return color.opacity(0.8)
        }
        return color.opacity(0.25)
    }
}

// MARK: - Labeled Action Button (icon + text, same style as ActionButton)

struct LabeledActionButton: View {
    let icon: String
    let label: String
    let color: Color
    var tooltip: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(isHovered ? .white : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture {
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPressed = false
                action()
            }
        }
        .help(tooltip ?? "")
    }

    private var backgroundColor: Color {
        if isPressed {
            return color.opacity(0.7)
        }
        else if isHovered {
            return color.opacity(0.6)
        }
        return color.opacity(0.1)
    }

    private var borderColor: Color {
        if isHovered {
            return color.opacity(0.8)
        }
        return color.opacity(0.25)
    }
}
