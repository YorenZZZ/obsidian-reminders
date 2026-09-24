import Foundation
import ServiceManagement

/// Open-at-login on every supported macOS: `SMAppService` on macOS 13+, a
/// per-user LaunchAgent on older systems (launchd reads it at the next login).
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        guard let plist = NSDictionary(contentsOf: agentURL),
              let args = plist["ProgramArguments"] as? [String] else { return false }
        return args.last == Bundle.main.bundlePath
    }

    static var statusDescription: String {
        if #available(macOS 13.0, *) { return "\(SMAppService.mainApp.status.rawValue)" }
        return isEnabled ? "launch agent" : "none"
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        if enabled {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: NSDictionary = [
                "Label": agentLabel,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try plist.write(to: agentURL)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }

    private static var agentLabel: String {
        (Bundle.main.bundleIdentifier ?? "io.github.yorenzzz.obsidian-reminders") + ".login"
    }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
}
