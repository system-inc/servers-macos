import AppKit
import Combine
import SwiftUI

// MARK: - Window State Persistence (multi-monitor aware)

struct SavedWindowState: Codable {
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
    let screenID: String
    let screenFrameX: Double
    let screenFrameY: Double
    let screenFrameWidth: Double
    let screenFrameHeight: Double

    /// Nil when the window is on no screen and there is no main screen either, so there's no
    /// screen to remember it against.
    init?(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return nil }

        let frame = window.frame
        self.frameX = frame.origin.x
        self.frameY = frame.origin.y
        self.frameWidth = frame.size.width
        self.frameHeight = frame.size.height

        self.screenID = screen.screenIdentifier

        let screenFrame = screen.visibleFrame
        self.screenFrameX = screenFrame.origin.x
        self.screenFrameY = screenFrame.origin.y
        self.screenFrameWidth = screenFrame.size.width
        self.screenFrameHeight = screenFrame.size.height
    }
}

enum WindowStateManager {
    private static let keyPrefix = "WindowState_"

    static func save(window: NSWindow, name: String) {
        if let state = SavedWindowState(window: window),
            let data = try? JSONEncoder().encode(state)
        {
            UserDefaults.standard.set(data, forKey: keyPrefix + name)
        }
    }

    static func restore(window: NSWindow, name: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + name),
            let state = try? JSONDecoder().decode(SavedWindowState.self, from: data)
        else {
            return false
        }

        let savedFrame = NSRect(
            x: state.frameX,
            y: state.frameY,
            width: state.frameWidth,
            height: state.frameHeight,
        )

        // Try exact screen by identifier (name + resolution)
        if let targetScreen = NSScreen.screen(forIdentifier: state.screenID) {
            let adjusted = adjustFrame(savedFrame, from: state, to: targetScreen)
            window.setFrame(adjusted, display: true)
            return true
        }

        // Fallback: check if saved frame is mostly visible on any screen
        if frameIsVisible(savedFrame) {
            window.setFrame(savedFrame, display: true)
            return true
        }

        // Last resort: saved size, centered on main
        if let main = NSScreen.main {
            let vis = main.visibleFrame
            let centered = NSRect(
                x: vis.midX - savedFrame.width / 2,
                y: vis.midY - savedFrame.height / 2,
                width: savedFrame.width,
                height: savedFrame.height,
            )
            window.setFrame(centered, display: true)
            return true
        }

        return false
    }

    private static func adjustFrame(_ saved: NSRect, from state: SavedWindowState, to screen: NSScreen) -> NSRect {
        let oldScreen = NSRect(
            x: state.screenFrameX,
            y: state.screenFrameY,
            width: state.screenFrameWidth,
            height: state.screenFrameHeight,
        )
        let current = screen.visibleFrame

        // Both are visible frames of real screens, never empty or negative, so Swift's
        // standardized comparison and intersection agree with the C functions here.
        if oldScreen == current { return saved }

        let relativeX = (saved.origin.x - oldScreen.origin.x) / oldScreen.width
        let relativeY = (saved.origin.y - oldScreen.origin.y) / oldScreen.height

        var adjusted = saved
        adjusted.origin.x = current.origin.x + relativeX * current.width
        adjusted.origin.y = current.origin.y + relativeY * current.height
        adjusted.size.width = min(adjusted.size.width, current.width)
        adjusted.size.height = min(adjusted.size.height, current.height)

        // Clamp on-screen
        if adjusted.maxX > current.maxX { adjusted.origin.x = current.maxX - adjusted.size.width }
        if adjusted.maxY > current.maxY { adjusted.origin.y = current.maxY - adjusted.size.height }
        if adjusted.origin.x < current.origin.x { adjusted.origin.x = current.origin.x }
        if adjusted.origin.y < current.origin.y { adjusted.origin.y = current.origin.y }

        return adjusted
    }

    private static func frameIsVisible(_ frame: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let intersection = frame.intersection(screen.visibleFrame)
            let area = frame.width * frame.height
            if area > 0 && (intersection.width * intersection.height) / area > 0.5 {
                return true
            }
        }
        return false
    }
}

// MARK: - Log Window Controller

class LogWindowController {
    private static var windows: [String: NSWindow] = [:]

    /// One delegate for every log window. `NSWindow.delegate` is weak, so this keeps it alive,
    /// and it finds the server for a window by looking the window up in `windows`.
    private static let windowDelegate = WindowDelegate()

    static func show(serverId: String, manager: ServerManager) {
        // If window already exists, bring it to front
        if let existingWindow = windows[serverId] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let state = manager.serverStates[serverId] else { return }

        let server = state.server
        let openBrowser: (() -> Void)? =
            server.port != nil
            ? {
                if let url = server.browserUrl {
                    NSWorkspace.shared.open(url)
                }
            } : nil

        let apiPort = manager.settings?.resolvedApiPort ?? 7378
        let logView = LogView(
            serverState: state,
            onStart: { manager.start(serverId: serverId) },
            onStop: { manager.stop(serverId: serverId) },
            onRestart: { manager.restart(serverId: serverId) },
            onOpenBrowser: openBrowser,
            onCopyInstructions: {
                ServerInstructions.copyToClipboard(for: server, apiPort: apiPort)
            },
        )
        let hostingController = NSHostingController(rootView: logView)

        // Default quarter-screen frame
        let defaultFrame: NSRect
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let width = screenFrame.width / 2
            let height = screenFrame.height / 2
            let x = screenFrame.origin.x + (screenFrame.width - width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - height) / 2
            defaultFrame = NSRect(x: x, y: y, width: width, height: height)
        }
        else {
            defaultFrame = NSRect(x: 0, y: 0, width: 900, height: 600)
        }

        // Create window
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )

        window.minSize = NSSize(width: 600, height: 400)

        window.title = server.browserUrl.map { "\(server.name) (\($0.absoluteString))" } ?? server.name
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        // Restore saved position, size, and screen
        _ = WindowStateManager.restore(window: window, name: "LogWindow_\(serverId)")

        // Handle window close + save state on move/resize
        window.delegate = windowDelegate

        windows[serverId] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        updateDockIconVisibility()
    }

    static func close(serverId: String) {
        windows[serverId]?.close()
        windows.removeValue(forKey: serverId)
        updateDockIconVisibility()
    }

    static func updateDockIconVisibility() {
        if windows.isEmpty && !SettingsWindowController.isOpen {
            NSApp.setActivationPolicy(.accessory)
        }
        else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private class WindowDelegate: NSObject, NSWindowDelegate {
        /// The window posting the notification and the server it shows logs for.
        private func logWindow(_ notification: Notification) -> (window: NSWindow, serverId: String)? {
            guard let window = notification.object as? NSWindow,
                let serverId = LogWindowController.windows.first(where: { $0.value === window })?.key
            else {
                return nil
            }
            return (window, serverId)
        }

        private func saveState(_ logWindow: (window: NSWindow, serverId: String)) {
            WindowStateManager.save(window: logWindow.window, name: "LogWindow_\(logWindow.serverId)")
        }

        func windowDidMove(_ notification: Notification) {
            if let logWindow = logWindow(notification) { saveState(logWindow) }
        }

        func windowDidResize(_ notification: Notification) {
            if let logWindow = logWindow(notification) { saveState(logWindow) }
        }

        func windowWillClose(_ notification: Notification) {
            if let logWindow = logWindow(notification) {
                saveState(logWindow)
                LogWindowController.windows.removeValue(forKey: logWindow.serverId)
            }
            LogWindowController.updateDockIconVisibility()
        }
    }
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var serverState: ServerState
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    var onOpenBrowser: (() -> Void)? = nil
    var onCopyInstructions: (() -> Void)? = nil
    @State private var autoScroll = true
    @State private var searchText = ""
    @State private var showTimestamps = false
    @State private var errorsOnly = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                ServerControlButtons(
                    status: serverState.status,
                    onStart: onStart,
                    onStop: onStop,
                    onRestart: onRestart,
                    onOpenBrowser: onOpenBrowser,
                    onCopyInstructions: onCopyInstructions,
                    size: .medium,
                )

                Spacer()

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                Toggle("Errors", isOn: $errorsOnly)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
                    .fixedSize()

                Toggle("Time", isOn: $showTimestamps)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
                    .fixedSize()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
                    .fixedSize()

                ActionButton(icon: "trash", color: .gray, enabled: true, size: .medium, tooltip: "Clear Logs") {
                    serverState.clearLogs()
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .fixedSize(horizontal: false, vertical: true)
            .clipped()

            Divider()

            // Log content
            LogTextView(
                logs: filteredLogs,
                searchText: searchText,
                autoScroll: autoScroll,
                showTimestamps: showTimestamps,
                timestamps: filteredTimestamps,
            )

            Divider()

            // Footer
            HStack {
                Text(String(serverState.logBuffer.count) + " lines")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if !searchText.isEmpty {
                    Text("(" + String(filteredLogs.count) + " matching)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if serverState.status == .running {
                    let cpu = serverState.cpuUsage
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                        Text(CpuPercentText.adaptive(cpu))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(cpu > 100 ? .red : cpu > 50 ? .orange : .secondary)
                }

                if let port = serverState.server.port {
                    Text("Port " + String(port))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func isErrorLine(_ line: String) -> Bool {
        line.contains("[stderr]") || line.lowercased().contains("error") || line.lowercased().contains("warn")
    }

    var filteredLogs: [String] {
        var lines = serverState.logBuffer
        if errorsOnly {
            lines = lines.filter { isErrorLine($0) }
        }
        if !searchText.isEmpty {
            lines = lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return lines
    }

    var filteredTimestamps: [Date] {
        let zipped = Array(zip(serverState.logBuffer, serverState.logTimestamps))
        var filtered = zipped
        if errorsOnly {
            filtered = filtered.filter { isErrorLine($0.0) }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.0.localizedCaseInsensitiveContains(searchText) }
        }
        return filtered.map { $0.1 }
    }
}

// MARK: - Native NSTextView wrapper

struct LogTextView: NSViewRepresentable {
    let logs: [String]
    let searchText: String
    let autoScroll: Bool
    let showTimestamps: Bool
    let timestamps: [Date]

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var wasAtBottom = true
        var isFirstUpdate = true
        var observation: (any NSObjectProtocol)?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // `scrollableTextView()` always builds its document view as a text view. Were that ever
        // to change, the window shows an empty scroll view instead of crashing.
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        textView.isIncrementalSearchingEnabled = true
        textView.usesFindBar = true

        // Re-scroll to bottom on resize if we were at bottom
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.observation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main,
        ) { [weak scrollView, weak coordinator] _ in
            // Registered on the main queue, so it's delivered there.
            MainActor.assumeIsolated {
                guard let scrollView,
                    let coordinator,
                    let textView = scrollView.documentView as? NSTextView
                else { return }
                if coordinator.wasAtBottom {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let attributedString = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        for (index, line) in logs.enumerated() {
            // Line number (inline, not selectable-looking), right-aligned in four columns
            let lineNumber = String(index + 1)
            attributedString.append(
                NSAttributedString(
                    string: String(repeating: " ", count: max(0, 4 - lineNumber.count)) + lineNumber + "  ",
                    attributes: [.font: lineNumberFont, .foregroundColor: NSColor.tertiaryLabelColor],
                )
            )

            // Timestamp
            if showTimestamps && index < timestamps.count {
                let ts = Self.timestampFormatter.string(from: timestamps[index])
                attributedString.append(
                    NSAttributedString(
                        string: "\(ts)  ",
                        attributes: [.font: defaultFont, .foregroundColor: NSColor.tertiaryLabelColor],
                    )
                )
            }

            // Line content with color + search highlighting
            let color = colorForLine(line)

            if !searchText.isEmpty {
                let fullLine = line + "\n"
                let mutableLine = NSMutableAttributedString(
                    string: fullLine,
                    attributes: [.font: defaultFont, .foregroundColor: color],
                )
                let nsLine = fullLine as NSString
                var searchRange = NSRange(location: 0, length: nsLine.length)
                while searchRange.location < nsLine.length {
                    let foundRange = nsLine.range(of: searchText, options: .caseInsensitive, range: searchRange)
                    if foundRange.location == NSNotFound { break }
                    mutableLine.addAttributes([.backgroundColor: NSColor.findHighlightColor], range: foundRange)
                    searchRange.location = foundRange.location + foundRange.length
                    searchRange.length = nsLine.length - searchRange.location
                }
                attributedString.append(mutableLine)
            }
            else {
                attributedString.append(
                    NSAttributedString(
                        string: line + "\n",
                        attributes: [.font: defaultFont, .foregroundColor: color],
                    )
                )
            }
        }

        if textView.attributedString() != attributedString {
            let wasAtBottom = context.coordinator.isFirstUpdate || isScrolledToBottom(scrollView)
            context.coordinator.wasAtBottom = autoScroll && wasAtBottom
            // `textStorage` is `unowned(unsafe)` in AppKit. The text view owns its storage for as
            // long as the view lives, and the view is alive here, on the main actor, for this call.
            unsafe textView.textStorage?.setAttributedString(attributedString)

            if autoScroll && wasAtBottom {
                textView.scrollToEndOfDocument(nil)
                // Also scroll after layout completes for first render
                if context.coordinator.isFirstUpdate {
                    DispatchQueue.main.async {
                        textView.scrollToEndOfDocument(nil)
                    }
                }
            }
            context.coordinator.isFirstUpdate = false
        }
        // Keep tracking scroll position for resize handling
        context.coordinator.wasAtBottom = autoScroll && isScrolledToBottom(scrollView)
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        // With no document there's nothing to scroll, so it reads as already at the bottom.
        guard let documentView = scrollView.documentView else { return true }
        let currentScroll = clipView.bounds.origin.y + clipView.bounds.height
        let documentHeight = documentView.frame.height
        return currentScroll >= documentHeight - 50
    }

    private func colorForLine(_ line: String) -> NSColor {
        if line.contains("[stderr]") || line.lowercased().contains("error") {
            return NSColor.systemRed
        }
        else if line.lowercased().contains("warn") {
            return NSColor.systemOrange
        }
        else if line.hasPrefix("[system]") {
            return NSColor.systemBlue
        }
        return NSColor.labelColor
    }
}
