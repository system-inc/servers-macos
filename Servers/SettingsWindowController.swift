import AppKit
import Combine
import ServiceManagement
import SwiftUI
import os

// MARK: - Settings Window Controller

class SettingsWindowController {
    private static var window: NSWindow?

    /// `NSWindow.delegate` is weak, so the controller keeps the settings window's delegate alive.
    private static let windowDelegate = SettingsWindowDelegate()

    static func show() {
        // If window already exists, bring it to front
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsContentView()
        let hostingController = NSHostingController(rootView: settingsView)

        // Default frame
        let defaultFrame: NSRect
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let width: CGFloat = 680
            let height: CGFloat = 600
            let x = screenFrame.origin.x + (screenFrame.width - width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - height) / 2
            defaultFrame = NSRect(x: x, y: y, width: width, height: height)
        }
        else {
            defaultFrame = NSRect(x: 0, y: 0, width: 680, height: 600)
        }

        let win = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )

        win.minSize = NSSize(width: 560, height: 400)
        win.title = "Settings"
        win.contentViewController = hostingController
        win.isReleasedWhenClosed = false

        // Restore saved position
        _ = WindowStateManager.restore(window: win, name: "SettingsWindow")

        // Handle window close + save state
        win.delegate = windowDelegate

        window = win
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)

        LogWindowController.updateDockIconVisibility()
    }

    static func close() {
        window?.close()
    }

    static var isOpen: Bool {
        window != nil
    }

    private class SettingsWindowDelegate: NSObject, NSWindowDelegate {
        private func saveState(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                WindowStateManager.save(window: window, name: "SettingsWindow")
            }
        }

        func windowDidMove(_ notification: Notification) { saveState(notification) }
        func windowDidResize(_ notification: Notification) { saveState(notification) }

        func windowWillClose(_ notification: Notification) {
            saveState(notification)
            SettingsWindowController.window = nil
            LogWindowController.updateDockIconVisibility()
        }
    }
}

// MARK: - Settings Content View

struct SettingsContentView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // General section
                GeneralSettingsSection(viewModel: viewModel)

                Divider()

                // Servers section
                ServerListSection(viewModel: viewModel)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 350)
    }
}

// MARK: - View Model

class SettingsViewModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var apiPortString: String = "7378" {
        didSet { apiPortDirty = apiPortString != savedApiPortString }
    }
    @Published var apiPortDirty: Bool = false
    @Published var launchAtLogin: Bool = false
    private var savedApiPortString: String = "7378"
    @Published var editingServerId: String? = nil
    @Published var editDraft = ServerEditDraft()
    @Published var isAddingNew: Bool = false

    init() {
        load()
    }

    func load() {
        if let settings = ServerSettings.load() {
            servers = settings.servers
            let portString = String(settings.resolvedApiPort)
            savedApiPortString = portString
            apiPortString = portString
            apiPortDirty = false
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func save() {
        let port = Int(apiPortString) ?? 7378
        let settings = ServerSettings(servers: servers, apiPort: port)
        settings.save()
        ServerManager.shared.reloadSettings()
    }

    func saveApiPort() {
        savedApiPortString = apiPortString
        apiPortDirty = false
        save()
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            }
            else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        }
        catch {
            Logger.settings.error("Failed to toggle launch at login: \(error, privacy: .public)")
        }
    }

    func deleteServer(at index: Int) {
        let server = servers[index]
        // Stop if running
        ServerManager.shared.stop(serverId: server.id)
        servers.remove(at: index)
        save()
    }

    func toggleVisibility(at index: Int) {
        let server = servers[index]
        let newVisible = !server.isVisible
        servers[index] = Server(
            id: server.id,
            name: server.name,
            path: server.path,
            command: server.command,
            port: server.port,
            hostname: server.hostname,
            healthCheckPath: server.healthCheckPath,
            https: server.https,
            autoStart: server.autoStart,
            visible: newVisible,
        )
        save()
    }

    func startEditing(server: Server) {
        editingServerId = server.id
        isAddingNew = false
        editDraft = ServerEditDraft(from: server)
    }

    func startAddingNew() {
        editingServerId = nil
        isAddingNew = true
        editDraft = ServerEditDraft()
    }

    func cancelEdit() {
        editingServerId = nil
        isAddingNew = false
    }

    func saveEdit() {
        guard editDraft.isValid else { return }

        let newServer = editDraft.toServer()

        if isAddingNew {
            servers.append(newServer)
        }
        else if let editingId = editingServerId,
            let index = servers.firstIndex(where: { $0.id == editingId })
        {
            servers[index] = newServer
        }

        editingServerId = nil
        isAddingNew = false
        save()
    }

    func moveServer(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func moveServerUp(at index: Int) {
        guard index > 0 else { return }
        servers.swapAt(index, index - 1)
        save()
    }

    func moveServerDown(at index: Int) {
        guard index < servers.count - 1 else { return }
        servers.swapAt(index, index + 1)
        save()
    }
}

// MARK: - Server Edit Draft

struct ServerEditDraft {
    var id: String = ""
    var name: String = ""
    var command: String = ""
    var path: String = ""
    var hostname: String = "localhost"
    var port: String = ""
    var https: Bool = false
    var healthCheckPath: String = "/"
    var autoStart: Bool = false
    var visible: Bool = true

    init() {}

    init(from server: Server) {
        id = server.id
        name = server.name
        command = server.command
        path = server.path
        hostname = server.hostname
        port = server.port.map { String($0) } ?? ""
        https = server.useHttps
        healthCheckPath = server.healthCheckPath ?? "/"
        autoStart = server.shouldAutoStart
        visible = server.isVisible
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty && !id.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func toServer() -> Server {
        Server(
            id: id.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            path: path.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            port: Int(port),
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            healthCheckPath: healthCheckPath.isEmpty ? "/" : healthCheckPath,
            https: https ? true : nil,
            autoStart: autoStart ? true : nil,
            visible: visible ? nil : false,
        )
    }
}

// MARK: - General Settings Section

struct GeneralSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { _ in viewModel.toggleLaunchAtLogin() },
                    ),
                )
                .toggleStyle(.checkbox)

                Spacer()

                HStack(spacing: 6) {
                    Text("API Port:")
                    TextField("7378", text: $viewModel.apiPortString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    if viewModel.apiPortDirty {
                        Button("Save") { viewModel.saveApiPort() }
                            .controlSize(.small)
                        Text("Restart required")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - Server List Section

struct ServerListSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Servers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                LabeledActionButton(
                    icon: "square.and.pencil",
                    label: "~/.servers/settings.json",
                    color: .gray,
                    tooltip: "Open in VS Code",
                ) {
                    let path = NSString(string: "~/.servers/settings.json").expandingTildeInPath
                    let task = Process()
                    task.executableURL = URL(
                        fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
                    )
                    task.arguments = [path]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    do {
                        try task.run()
                    }
                    catch {
                        // Without VS Code installed there's nothing to open; say so in the log.
                        Logger.settings.error("Failed to open settings in VS Code: \(error, privacy: .public)")
                    }
                }

                if !viewModel.isAddingNew && viewModel.editingServerId == nil {
                    ActionButton(icon: "plus", color: .green, enabled: true, size: .small, tooltip: "Add server") {
                        viewModel.startAddingNew()
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.servers.enumerated()), id: \.element.id) { index, server in
                    VStack(spacing: 0) {
                        if viewModel.editingServerId == server.id {
                            ServerEditForm(viewModel: viewModel, isNew: false)
                                .padding(12)
                        }
                        else {
                            ServerRow(
                                server: server,
                                index: index,
                                serverCount: viewModel.servers.count,
                                viewModel: viewModel,
                            )
                        }

                        if index < viewModel.servers.count - 1 {
                            Divider()
                        }
                    }
                }

                if viewModel.isAddingNew {
                    if !viewModel.servers.isEmpty { Divider() }
                    ServerEditForm(viewModel: viewModel, isNew: true)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

        }
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let index: Int
    let serverCount: Int
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var portString: String {
        server.port.map { ":\($0)" } ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            // Server info (clickable to edit)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(server.isVisible ? 1.0 : 0.5)

                    if server.shouldAutoStart {
                        Text("Auto")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    if !portString.isEmpty {
                        Text(portString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(server.command)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Always-visible actions
            HStack(spacing: 4) {
                ActionButton(icon: "chevron.up", color: .gray, enabled: index > 0, size: .small, tooltip: "Move up") {
                    viewModel.moveServerUp(at: index)
                }

                ActionButton(
                    icon: "chevron.down",
                    color: .gray,
                    enabled: index < serverCount - 1,
                    size: .small,
                    tooltip: "Move down",
                ) {
                    viewModel.moveServerDown(at: index)
                }

                ActionButton(
                    icon: server.isVisible ? "eye.fill" : "eye.slash",
                    color: server.isVisible ? .blue : .gray,
                    enabled: true,
                    size: .small,
                    tooltip: server.isVisible ? "Hide from menu" : "Show in menu",
                ) {
                    viewModel.toggleVisibility(at: index)
                }

                ActionButton(icon: "trash", color: .red, enabled: true, size: .small, tooltip: "Delete server") {
                    showDeleteConfirm = true
                }
                .confirmationDialog("Delete \(server.name)?", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        viewModel.deleteServer(at: index)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove the server from settings. If it's running, it will be stopped.")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { viewModel.startEditing(server: server) }
    }
}

// MARK: - Server Edit Form

struct ServerEditForm: View {
    @ObservedObject var viewModel: SettingsViewModel
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isNew {
                Text("New Server")
                    .font(.system(size: 13, weight: .semibold))
            }

            fieldRow("Name:", $viewModel.editDraft.name, placeholder: "My Server")

            HStack(spacing: 8) {
                fieldRow("ID:", $viewModel.editDraft.id, placeholder: "my-server")
                if !isNew {
                    Text("(read-only)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(!isNew)
            .opacity(isNew ? 1.0 : 0.6)

            fieldRow("Command:", $viewModel.editDraft.command, placeholder: "pnpm dev")

            HStack(spacing: 8) {
                Text("Path:")
                    .font(.system(size: 12))
                    .frame(width: 80, alignment: .trailing)
                TextField("~/Projects/my-project", text: $viewModel.editDraft.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if !viewModel.editDraft.path.isEmpty {
                        let expanded = NSString(string: viewModel.editDraft.path).expandingTildeInPath
                        panel.directoryURL = URL(fileURLWithPath: expanded)
                    }
                    if panel.runModal() == .OK, let url = panel.url {
                        // Convert to tilde path if under home
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        if url.path.hasPrefix(home) {
                            viewModel.editDraft.path = "~" + url.path.dropFirst(home.count)
                        }
                        else {
                            viewModel.editDraft.path = url.path
                        }
                    }
                }
                .controlSize(.small)
            }

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Hostname:")
                        .font(.system(size: 12))
                        .frame(width: 80, alignment: .trailing)
                    TextField("localhost", text: $viewModel.editDraft.hostname)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 180)
                }

                HStack(spacing: 8) {
                    Text("Port:")
                        .font(.system(size: 12))
                    TextField("", text: $viewModel.editDraft.port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 70)
                }
            }

            fieldRow("Health Path:", $viewModel.editDraft.healthCheckPath, placeholder: "/")

            HStack(spacing: 20) {
                Text("")
                    .frame(width: 80)

                Toggle("HTTPS", isOn: $viewModel.editDraft.https)
                    .toggleStyle(.checkbox)

                Toggle("Auto Start", isOn: $viewModel.editDraft.autoStart)
                    .toggleStyle(.checkbox)

                Toggle("Visible", isOn: $viewModel.editDraft.visible)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { viewModel.saveEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.editDraft.isValid)
            }
            .padding(.top, 4)
        }
    }

    private func fieldRow(_ label: String, _ binding: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 80, alignment: .trailing)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}
