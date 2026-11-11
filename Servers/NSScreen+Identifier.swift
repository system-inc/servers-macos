import AppKit

// MARK: - Screen Identity (multi-monitor aware window state)

extension NSScreen {
    /// Stable identifier using localizedName + frame as a fingerprint
    var screenIdentifier: String {
        "\(localizedName)_\(frame.width)x\(frame.height)"
    }

    static func screen(forIdentifier identifier: String) -> NSScreen? {
        NSScreen.screens.first { $0.screenIdentifier == identifier }
    }
}
