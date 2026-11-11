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

        // Kill every managed dev server's process group now and clear their ports. Not stopAll():
        // its one-second `SIGKILL` fallback runs on the main queue, which never turns again
        // before exit, so a server that ignores `SIGTERM` would outlive the app.
        ServerManager.shared.forceStopAll()

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
