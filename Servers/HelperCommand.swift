import Foundation

// MARK: - Helper Commands

/// Runs a short-lived helper (ps, lsof, pkill) so the child can never outlive the call.
///
/// Every path reaps the child. Output is drained to end of file before waiting, because a
/// child whose output overruns the pipe buffer blocks on its write and never exits while the
/// parent waits for it to exit first. That deadlock is how Servers.app once held 80 hung
/// `/bin/ps` children: the old CPU sampler waited before reading, and on a Mac with a few
/// thousand processes the table no longer fit in the pipe. A child that runs past its deadline
/// is killed, which closes its end of the pipe, and is then reaped like any other.
///
/// Nonisolated because it runs on background queues, and so the watchdog closure is too: it
/// fires on a global queue, and a closure that inherited the main actor would trap there.
nonisolated enum HelperCommand {
    /// The child's standard output, or nil when it couldn't launch or was killed at its deadline.
    static func output(_ executablePath: String, arguments: [String], timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        }
        catch {
            return nil
        }

        let timedOutLock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            // Still running means not yet reaped, so the pid can't have been reused.
            guard process.isRunning else { return }
            timedOutLock.lock()
            timedOut = true
            timedOutLock.unlock()
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain first: returns at end of file, when the child exits or the watchdog kills it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        do {
            try pipe.fileHandleForReading.close()
        }
        catch {
            // The output is already read whole; a handle that won't close is released with the pipe.
        }
        process.waitUntilExit()
        watchdog.cancel()

        timedOutLock.lock()
        defer { timedOutLock.unlock() }
        return timedOut ? nil : data
    }
}
