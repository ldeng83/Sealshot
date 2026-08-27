import AppKit

/// Self-relaunch for permission flows: macOS applies the Screen Recording
/// grant at app launch, so after granting the app must restart to use it.
enum AppRelauncher {

    /// Spawns a detached shell that waits for THIS process to actually exit,
    /// then opens the bundle, and terminates. A fixed sleep raced shutdown:
    /// when termination took longer (autosave, observer teardown), `open`
    /// hit the dying instance and the relaunch silently never happened.
    /// Polling the old pid removes the race; the wait is capped so a stuck
    /// shutdown can't loop forever, and plain `open` (no `-n`) merely
    /// activates the old instance in that worst case instead of doubling it.
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        i=0
        while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt 100 ]; do
            /bin/sleep 0.1
            i=$((i+1))
        done
        /usr/bin/open "\(bundlePath)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }
}
