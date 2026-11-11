import Darwin
import SwiftUI
import os

@main
struct ServersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            PlaceholderSettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    private var sigtermSource: (any DispatchSourceSignal)?
    private var sigintSource: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()

        // Hide dock icon - we're a menubar app
        NSApp.setActivationPolicy(.accessory)

        // Set up signal handlers for graceful shutdown
        setupSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up when app is terminating normally
        gracefulShutdown()
    }

    private func setupSignalHandlers() {
        // Ignore default signal handling so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        // Handle `SIGTERM` (sent by `pkill -TERM`)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in
            Logger.app.notice("Received SIGTERM, shutting down gracefully")
            self?.gracefulShutdown()
            exit(0)
        }
        sigtermSource?.resume()

        // Handle `SIGINT` (Ctrl+C)
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource?.setEventHandler { [weak self] in
            Logger.app.notice("Received SIGINT, shutting down gracefully")
            self?.gracefulShutdown()
            exit(0)
        }
        sigintSource?.resume()
    }

    private func gracefulShutdown() {
        Logger.app.notice("Stopping all servers")

        // Stop the API server
        statusBarController?.serverApi?.stop()

        // Stop all managed dev servers (this kills the process groups)
        ServerManager.shared.stopAll()

        // Give processes a moment to die
        Thread.sleep(forTimeInterval: 0.5)

        Logger.app.notice("Shutdown complete")
    }
}

struct PlaceholderSettingsView: View {
    var body: some View {
        Text("Use Settings from the menubar.")
            .padding()
            .frame(width: 300, height: 100)
    }
}
