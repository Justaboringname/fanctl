// Talks to fanctld (the root LaunchDaemon installed by install.sh) through files only:
// it publishes /var/run/fanctl.status, and we write the user-owned control file it polls.
import Foundation

enum FanDaemon {
    struct Status: Equatable {
        var control = "", setting = "auto", manual = false, guardTripped = false
        /// "", "guard", "no-sensors" or "read-error" (see write_status in fanctl.c)
        var reason = ""
    }

    /// The Makefile records the checkout the app was built from in Info.plist.
    static var installCommand: String {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "FanctlSourceDir") as? String, !dir.isEmpty else {
            return "sudo ./install.sh"
        }
        return "sudo '\(dir.replacingOccurrences(of: "'", with: "'\\''"))/install.sh'"
    }

    /// nil when the status file is missing or stale (daemon not running).
    static func read() -> Status? {
        let path = "/var/run/fanctl.status"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mtime) < 15,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var st = Status()
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "control": st.control = kv[1]
            case "setting": st.setting = kv[1]
            case "mode": st.manual = kv[1] == "manual"
            case "guard": st.guardTripped = kv[1] == "1"
            case "reason": st.reason = kv[1]
            default: break
            }
        }
        return st.control.isEmpty ? nil : st
    }

    /// "auto", "<rpm>" or "<N>%". Atomic write (temp file + rename) so the daemon never reads half a line.
    static func apply(_ setting: String) throws {
        guard let st = read() else { throw CocoaError(.fileNoSuchFile) }
        try (setting + "\n").write(toFile: st.control, atomically: true, encoding: .utf8)
    }
}
