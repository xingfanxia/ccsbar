import Foundation

/// Reads `~/.clauth/status.json` and drives `~/.clauth/clauthd.sock`.
///
/// Display is a plain file read (the daemon rewrites status.json every tick, so
/// polling the file is fresh within a second and needs no connection). `switch`
/// and `refresh` prefer the socket for low latency and fall back to shelling
/// `clauth <name>` when the daemon (hence the socket) isn't running.
enum DaemonClient {
    static var clauthDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clauth")
    }
    static var statusURL: URL { clauthDir.appendingPathComponent("status.json") }
    static var socketPath: String { clauthDir.appendingPathComponent("clauthd.sock").path }

    // MARK: - Status (file)

    /// Read + decode status.json, or nil if absent/unparseable.
    static func readStatus() -> DaemonStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    /// mtime of status.json for cheap change detection.
    static func statusMtime() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// True when the daemon's control socket is present (a daemon is likely live).
    static var daemonSocketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - Commands

    /// Switch the global active profile. Socket first, `clauth <name>` fallback.
    static func switchTo(_ profile: String) {
        if sendCommand(["cmd": "switch", "profile": profile]) != nil { return }
        shellClauth([profile])
    }

    /// Force a usage re-fetch (all profiles when `profile` is nil). Socket only —
    /// there's no `clauth refresh` CLI, and a missed manual refresh is harmless
    /// (the daemon refreshes on its own cadence).
    static func refresh(_ profile: String?) {
        var cmd: [String: Any] = ["cmd": "refresh"]
        if let profile { cmd["profile"] = profile }
        _ = sendCommand(cmd)
    }

    // MARK: - Fallback configuration (socket only — needs a running daemon)

    /// Append a profile to the fallback chain.
    @discardableResult
    static func fallbackAdd(_ profile: String) -> Bool {
        sendCommand(["cmd": "fallback_add", "profile": profile]) != nil
    }

    /// Remove a profile from the fallback chain.
    @discardableResult
    static func fallbackRemove(_ profile: String) -> Bool {
        sendCommand(["cmd": "fallback_remove", "profile": profile]) != nil
    }

    /// Move a chain member one slot up (`up: true`) or down.
    @discardableResult
    static func fallbackMove(_ profile: String, up: Bool) -> Bool {
        sendCommand(["cmd": "fallback_move", "profile": profile, "dir": up ? "up" : "down"]) != nil
    }

    /// Set a profile's 5h auto-switch threshold (0…100).
    @discardableResult
    static func setThreshold(_ profile: String, _ value: Int) -> Bool {
        sendCommand(["cmd": "set_threshold", "profile": profile, "value": value]) != nil
    }

    /// Toggle wrap-off mode (switch every account off once the chain is spent).
    @discardableResult
    static func setWrapOff(_ on: Bool) -> Bool {
        sendCommand(["cmd": "set_wrap_off", "value": on]) != nil
    }

    // MARK: - Socket

    /// Send one newline-delimited JSON command and parse the reply object.
    @discardableResult
    private static func sendCommand(_ command: [String: Any]) -> [String: Any]? {
        guard let payload = try? JSONSerialization.data(withJSONObject: command),
              let reply = sendRaw(payload),
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              obj["ok"] as? Bool == true
        else { return nil }
        return obj
    }

    /// Per-call socket read/write deadline. A switch can hold the daemon's config
    /// lock across a ~3s `/usr/bin/security` Keychain rewrite; without a timeout a
    /// tile tap would block the caller for that whole window (and unboundedly if an
    /// "Always Allow" ACL prompt stalls). 2s bounds it (TECH-10 #25).
    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)
    /// Cap on a single reply so a misbehaving peer can't grow the buffer without
    /// limit; the daemon's replies are tens of bytes.
    private static let maxReplyBytes = 1 << 20

    /// Connect to the unix socket, write one line, read the reply. Returns nil on
    /// any failure (no socket, connect refused, timeout, short/empty read) so
    /// callers can fall back. MUST be called off the main actor (see `StatusModel`):
    /// the connect/write/read are blocking, and this is the beach-ball source #25.
    private static func sendRaw(_ payload: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Never let a write to a peer-closed fd raise SIGPIPE (fatal on macOS with
        // no handler) — surface it as an EPIPE return we already treat as failure.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        // Bound every blocking read/write so a stuck daemon can't wedge the caller.
        var tv = ioTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: CChar.self)
            for i in 0..<min(pathBytes.count, dst.count) {
                dst[i] = pathBytes[i]
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }

        var line = payload
        line.append(0x0A) // newline-delimited
        // Loop until the whole payload is written — a single write() may be partial.
        let wroteAll = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < line.count {
                let n = write(fd, base + sent, line.count - sent)
                if n <= 0 { return false } // EPIPE / timeout / error
                sent += n
            }
            return true
        }
        guard wroteAll else { return nil }

        // Read until the newline terminator or EOF — one read() may not carry the
        // whole reply. Bounded by maxReplyBytes and the recv timeout.
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while response.count < maxReplyBytes {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break } // EOF, timeout, or error
            response.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break } // reply is one line
        }
        return response.isEmpty ? nil : response
    }

    // MARK: - Shell fallback

    /// Locate the `clauth` binary: PATH, then the standard cargo bin.
    private static func clauthBinary() -> String? {
        let cargo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo/bin/clauth").path
        for candidate in ["/opt/homebrew/bin/clauth", "/usr/local/bin/clauth", cargo] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func shellClauth(_ args: [String]) {
        guard let bin = clauthBinary() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        try? proc.run()
    }
}
