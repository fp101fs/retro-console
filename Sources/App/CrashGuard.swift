import Foundation

// A crash inside a native core cannot be caught and survived from Swift. While a core is running
// a fatal-signal handler writes a small report to Application Support and exits; the next launch
// shows it in a message with a details box and lands in the library.

private var crashPathC: UnsafeMutablePointer<CChar>?
private var crashMessageC: UnsafeMutablePointer<CChar>?

private func crashSignalHandler(_ sig: Int32) {
    if let path = crashPathC, let message = crashMessageC {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, message, strlen(message))
            var digits: [UInt8] = []
            var n = Int(sig)
            repeat {
                digits.insert(UInt8(48 + n % 10), at: 0)
                n /= 10
            } while n > 0
            let prefix = "Signal: "
            _ = prefix.withCString { write(fd, $0, strlen($0)) }
            _ = digits.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
        _exit(70)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum CrashGuard {
    static func install() {
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }

    static func arm(core: String, game: String, system: String) {
        disarm()
        crashPathC = strdup(AppPaths.crashReport.path)
        let text = "A libretro core crashed while a game was running.\nCore: \(core)\nSystem: \(system)\nGame: \(game)\nDate: \(Date())\n"
        crashMessageC = strdup(text)
    }

    static func disarm() {
        let path = crashPathC, message = crashMessageC
        crashPathC = nil
        crashMessageC = nil
        if let path { free(path) }
        if let message { free(message) }
    }

    /// Report left by a previous run, removed once read.
    static func takePendingReport() -> String? {
        guard let text = try? String(contentsOf: AppPaths.crashReport, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: AppPaths.crashReport)
        return text
    }
}
