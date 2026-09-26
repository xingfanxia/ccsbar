import Foundation
import os

/// The outcome of reading `status.json` — distinguishes the states the panel must
/// render differently (TECH-4): a live snapshot, no file yet, an unsupported
/// schema (ccsbar out of date), or a corrupt/partial decode.
enum StatusRead: Sendable {
    case ok(DaemonStatus)
    case fileMissing
    case schemaUnsupported(Int)
    case decodeFailed
}

/// The outcome of reading `tokens.json` (TOK-4) — the machine-wide token snapshot,
/// versioned independently of status.json. Same four-way split as `StatusRead`, but
/// every non-ok case degrades to a HIDDEN strip (never a panel-level error state):
/// the token strip is ambient context, so a missing/newer/corrupt file just drops it.
enum TokensRead: Sendable {
    case ok(MachineTokens)
    case fileMissing
    case schemaUnsupported(Int)
    case decodeFailed
}

/// The outcome of a daemon command (TECH-11). The three cases must NOT collapse to
/// one nil: a daemon *rejection* (`ok:false` with an `error_code`) is authoritative
/// and must NOT trigger the daemon-ABSENCE shell fallback, and it carries an error
/// the UI is obligated to surface ('errors must be loud').
enum CommandOutcome: Sendable, Equatable {
    /// Accepted (`ok:true`), or the CLI fallback exited 0.
    case ok
    /// The daemon replied `ok:false` — a real rejection (unknown_profile, busy,
    /// auth_broken, invalid_value), or the CLI fallback exited non-zero.
    case daemonError(code: String, message: String)
    /// No daemon reachable (no socket / transport failure) AND no working CLI —
    /// nothing applied the command.
    case unreachable

    var errorMessage: String? {
        if case .daemonError(_, let message) = self { return message }
        return nil
    }
}

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
    static var tokensURL: URL { clauthDir.appendingPathComponent("tokens.json") }
    static var socketPath: String { clauthDir.appendingPathComponent("clauthd.sock").path }

    private static let log = Logger(subsystem: "com.clauth.ccsbar", category: "daemon-client")

    // MARK: - Status (file)

    /// Read status.json into one of four outcomes (TECH-4). The schema is probed
    /// BEFORE the full decode so a future schema bump reads as "ccsbar out of
    /// date", not "no daemon"; a genuine decode failure (corrupt/partial write) is
    /// logged (not silently swallowed) and reported distinctly from a missing file.
    static func readStatus() -> StatusRead {
        guard let data = try? Data(contentsOf: statusURL) else { return .fileMissing }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           !readsSchema(probe.schema) {
            return .schemaUnsupported(probe.schema)
        }
        do {
            return .ok(try JSONDecoder().decode(DaemonStatus.self, from: data))
        } catch {
            log.error("status.json decode failed: \(error.localizedDescription, privacy: .public)")
            return .decodeFailed
        }
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

    // MARK: - Machine tokens (file)

    /// Read tokens.json into one of four outcomes (TOK-4), mirroring `readStatus`:
    /// probe the schema BEFORE the full decode (a future schema bump reads as
    /// `.schemaUnsupported`, not `.decodeFailed`), and log — not silently swallow — a
    /// genuine decode failure. Every non-ok case leaves the caller to hide the strip.
    static func readTokens() -> TokensRead {
        guard let data = try? Data(contentsOf: tokensURL) else { return .fileMissing }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           probe.schema != supportedTokensSchema {
            return .schemaUnsupported(probe.schema)
        }
        do {
            return .ok(try JSONDecoder().decode(MachineTokens.self, from: data))
        } catch {
            log.error("tokens.json decode failed: \(error.localizedDescription, privacy: .public)")
            return .decodeFailed
        }
    }

    /// mtime of tokens.json for cheap change detection (its own cadence — the daemon
    /// rewrites tokens on a different schedule than status).
    static func tokensMtime() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: tokensURL.path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Commands

    /// How a switch dispatch resolved (CBAR4-3). The `accepted` vs `confirmedByCLI`
    /// split is load-bearing: a socket `accepted` still needs the daemon's next tick
    /// to LAND it (observe status.json), whereas a CLI switch is confirmed by its
    /// EXIT CODE and status.json will NOT move (only the daemon writes that file, and
    /// here it's dead) — watching mtime would false-fail the exact case (design §8).
    enum SwitchDispatch: Equatable, Sendable {
        case accepted                                 // socket ok — daemon applies on its next tick
        case confirmedByCLI                           // daemon unreachable; shelled `clauth` exited 0
        case refused(code: String, message: String)   // daemon rejected, or the CLI exited non-zero
        case unreachable                              // no socket AND no working CLI — nothing applied
    }

    /// Switch the global active profile. Socket first; on an UNREACHABLE daemon fall
    /// back to `clauth <name>` (the CLI does the switch itself). A daemon *rejection*
    /// (`ok:false`) is authoritative and does NOT fall back — falling back there would
    /// fire the daemon-absence path against a present daemon and hide the real error.
    static func switchTo(_ profile: String) -> SwitchDispatch {
        switchTo(profile, send: { sendCommand($0) }, cli: { shellClauth([profile]) })
    }

    /// Testable seam for the fallback POLICY (the feature's headline invariant): a
    /// daemon *rejection* returns `.refused` and must NOT shell — only an UNREACHABLE
    /// daemon (no socket / never delivered) falls back to the CLI. `send`/`cli` are
    /// injected in tests (`cli` asserts it's never reached on a rejection).
    static func switchTo(
        _ profile: String,
        send: ([String: Any]) -> CommandOutcome,
        cli: () -> CommandOutcome
    ) -> SwitchDispatch {
        switch send(["cmd": "switch", "profile": profile]) {
        case .ok:
            return .accepted
        case .daemonError(let code, let message):
            return .refused(code: code, message: message)
        case .unreachable:
            switch cli() {
            case .ok: return .confirmedByCLI
            case .daemonError(let code, let message): return .refused(code: code, message: message)
            case .unreachable: return .unreachable
            }
        }
    }

    /// Force a usage re-fetch (all profiles when `profile` is nil). Socket only —
    /// there's no `clauth refresh` CLI, and a missed manual refresh is harmless
    /// (the daemon refreshes on its own cadence).
    @discardableResult
    static func refresh(_ profile: String?) -> CommandOutcome {
        var cmd: [String: Any] = ["cmd": "refresh"]
        if let profile { cmd["profile"] = profile }
        return sendCommand(cmd)
    }

    // MARK: - Fallback configuration (socket only — needs a running daemon)

    /// Append a profile to the fallback chain.
    @discardableResult
    static func fallbackAdd(_ profile: String) -> CommandOutcome {
        sendCommand(["cmd": "fallback_add", "profile": profile])
    }

    /// Remove a profile from the fallback chain.
    @discardableResult
    static func fallbackRemove(_ profile: String) -> CommandOutcome {
        sendCommand(["cmd": "fallback_remove", "profile": profile])
    }

    /// Move a chain member one slot up (`up: true`) or down.
    @discardableResult
    static func fallbackMove(_ profile: String, up: Bool) -> CommandOutcome {
        sendCommand(["cmd": "fallback_move", "profile": profile, "dir": up ? "up" : "down"])
    }

    /// Set a profile's 5h auto-switch threshold (0…100).
    @discardableResult
    static func setThreshold(_ profile: String, _ value: Int) -> CommandOutcome {
        sendCommand(["cmd": "set_threshold", "profile": profile, "value": value])
    }

    /// Set a profile's exclusive last-resort flag (clauth `set_last_resort`, a
    /// threshold-independent bool). An OLD daemon without the command replies
    /// `ok:false` ("unknown cmd") → `.daemonError`, surfaced loudly by the caller —
    /// so the toggle never silently no-ops against a pre-`set_last_resort` daemon.
    @discardableResult
    static func setLastResort(_ profile: String, _ value: Bool) -> CommandOutcome {
        setLastResort(profile, value, send: { sendCommand($0) })
    }

    /// Testable seam mirroring `switchTo`'s: lets a test assert the command payload
    /// shape (cmd name, keys, and a real JSON bool — the daemon validates `value`
    /// with `as_bool`, so an int/string would be rejected) without a live socket.
    static func setLastResort(
        _ profile: String, _ value: Bool,
        send: ([String: Any]) -> CommandOutcome
    ) -> CommandOutcome {
        send(["cmd": "set_last_resort", "profile": profile, "value": value])
    }

    /// Set (or clear, `nil`) a member's per-account weekly-line override
    /// (clauth `set_member_weekly`; the chain-wide `set_weekly_threshold`
    /// value stays the default). Old-daemon contract as `setLastResort`.
    @discardableResult
    static func setMemberWeekly(_ profile: String, _ value: Double?) -> CommandOutcome {
        setMemberWeekly(profile, value, send: { sendCommand($0) })
    }

    /// Testable seam: the daemon clears on an explicit JSON null, so `nil`
    /// must encode as `NSNull`, never by dropping the key silently.
    static func setMemberWeekly(
        _ profile: String, _ value: Double?,
        send: ([String: Any]) -> CommandOutcome
    ) -> CommandOutcome {
        send(["cmd": "set_member_weekly", "profile": profile, "value": value ?? NSNull()])
    }

    /// Flip a member's `weekly gate` (clauth `set_check_weekly`): whether
    /// auto-switching checks its aggregate weekly line at all.
    @discardableResult
    static func setCheckWeekly(_ profile: String, _ value: Bool) -> CommandOutcome {
        sendCommand(["cmd": "set_check_weekly", "profile": profile, "value": value])
    }

    /// Flip a member's `scoped gate` (clauth `set_check_scoped`): whether a
    /// spent per-model week (e.g. 7d fable) takes it out of rotation.
    @discardableResult
    static func setCheckScoped(_ profile: String, _ value: Bool) -> CommandOutcome {
        sendCommand(["cmd": "set_check_scoped", "profile": profile, "value": value])
    }

    /// Toggle wrap-off mode (switch every account off once the chain is spent).
    @discardableResult
    static func setWrapOff(_ on: Bool) -> CommandOutcome {
        sendCommand(["cmd": "set_wrap_off", "value": on])
    }

    /// Set the chain-wide weekly (7d) exhaustion line (clauth
    /// `set_weekly_threshold`, 50…100). An OLD daemon without the command replies
    /// `ok:false` ("unknown cmd") → `.daemonError`, surfaced loudly by the caller.
    @discardableResult
    static func setWeeklyThreshold(_ value: Double) -> CommandOutcome {
        setWeeklyThreshold(value, send: { sendCommand($0) })
    }

    /// Testable seam mirroring `setLastResort`'s: asserts the payload shape (the
    /// daemon validates `value` with `as_f64` against 50…100) without a socket.
    static func setWeeklyThreshold(
        _ value: Double,
        send: ([String: Any]) -> CommandOutcome
    ) -> CommandOutcome {
        send(["cmd": "set_weekly_threshold", "value": value])
    }

    /// Rename a profile. The daemon validates the new name (charset + collision)
    /// synchronously and returns `ok:false` with a reason on rejection; on accept it
    /// renames the profile dir + every reference and re-links the credential mirror if
    /// the account is active (same tokens → the live session is untouched).
    @discardableResult
    static func rename(_ old: String, to new: String) -> CommandOutcome {
        sendCommand(["cmd": "rename", "profile": old, "new_name": new])
    }

    // MARK: - Socket

    /// The transport-level result of one socket round-trip, kept DISTINCT from the
    /// application-level `CommandOutcome` (M1/TECH-11): `sendCommand` must tell "no
    /// daemon" (safe for `switchTo` to shell-fallback) apart from "daemon was there
    /// but went quiet" (must NOT fall back — it likely already applied the command).
    private enum RawReply {
        /// Never connected: no socket file, connect refused, or the command couldn't
        /// even be written (nothing was delivered → safe to fall back).
        case noSocket
        /// Connected AND wrote the command, but got no usable reply before the read
        /// deadline (a switch can hold the daemon's lock across a ~3s Keychain rewrite,
        /// longer than the 2s read timeout). The daemon very likely applied it.
        case connectedNoReply
        /// Got a line back to classify.
        case reply(Data)
    }

    /// Send one newline-delimited JSON command and classify the reply (TECH-11).
    private static func sendCommand(_ command: [String: Any]) -> CommandOutcome {
        guard let payload = try? JSONSerialization.data(withJSONObject: command) else {
            return .unreachable
        }
        switch sendRaw(payload) {
        case .noSocket:
            return .unreachable
        case .connectedNoReply:
            // We reached the daemon and delivered the command; a missing reply is NOT
            // absence. Returning .unreachable here would let switchTo shell `clauth`,
            // DOUBLE-applying an already-applied switch (two Keychain rewrites, two
            // logout storms). Surface it loudly instead — errors must be loud.
            return .daemonError(
                code: "no_reply",
                message: "the daemon didn't confirm in time — it may still be applying the change"
            )
        case .reply(let data):
            return classifyReply(data)
        }
    }

    /// Pure classification of a raw socket reply into a [`CommandOutcome`] (split
    /// from the socket I/O so the ok / reject / unreachable branching is testable):
    /// `ok:true` → `.ok`; `ok:false` → `.daemonError(error_code, error)`; a nil,
    /// non-object, or unparseable reply → `.unreachable` (transport failure).
    static func classifyReply(_ reply: Data?) -> CommandOutcome {
        guard let reply,
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { return .unreachable }
        // Tolerate `"ok": true` OR a truthy `"ok": 1` — the daemon emits a real JSON
        // bool today, but a serializer swap must not turn a success into a spurious
        // error banner (defensive; M6/TECH-11).
        let ok = (obj["ok"] as? Bool) ?? (obj["ok"] as? NSNumber)?.boolValue
        if ok == true { return .ok }
        let code = obj["error_code"] as? String ?? "unknown"
        let message = obj["error"] as? String ?? "the daemon rejected the command"
        return .daemonError(code: code, message: message)
    }

    /// Per-call socket read/write deadline. A switch can hold the daemon's config
    /// lock across a ~3s `/usr/bin/security` Keychain rewrite; without a timeout a
    /// tile tap would block the caller for that whole window (and unboundedly if an
    /// "Always Allow" ACL prompt stalls). 2s bounds it (TECH-10 #25).
    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)
    /// Cap on a single reply so a misbehaving peer can't grow the buffer without
    /// limit; the daemon's replies are tens of bytes.
    private static let maxReplyBytes = 1 << 20

    /// Connect to the unix socket, write one line, read the reply. Distinguishes
    /// never-reached (`.noSocket`) from reached-but-silent (`.connectedNoReply`) so
    /// `sendCommand` can keep a reply-timeout from triggering the shell fallback
    /// (M1/TECH-11). MUST be called off the main actor (see `StatusModel`): the
    /// connect/write/read are blocking, and this is the beach-ball source #25.
    private static func sendRaw(_ payload: Data) -> RawReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noSocket }
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
        let pathBytes = socketPath.utf8CString // includes the trailing NUL
        // Refuse rather than silently truncate: a path that doesn't fit sun_path
        // (incl. its NUL) would connect to the WRONG socket (M7/TECH-11). Not
        // reachable for ~/.clauth/clauthd.sock, but truncation is a nasty failure.
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .noSocket
        }
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
        guard connected == 0 else { return .noSocket }

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
        // A failed write means the command was never delivered — the daemon didn't
        // apply anything, so a shell fallback here is safe (no double-apply).
        guard wroteAll else { return .noSocket }

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
        // Reached the daemon and delivered the command; an empty read is "went
        // quiet", NOT absence — sendCommand surfaces it instead of falling back.
        // A NON-empty buffer without its newline terminator is a TRUNCATED
        // reply (a >2s gap mid-reply hit the per-read timeout): the command
        // was delivered and may have been applied, so it must ALSO surface as
        // no-reply — feeding the fragment to classifyReply would fail JSON
        // parsing, misread as .unreachable, and trigger the CLI double-apply
        // fallback (timeout-sweep 2026-07-18; not reachable with today's
        // single-atomic-write replies, closed as defense-in-depth).
        if response.isEmpty || !response.contains(0x0A) {
            return .connectedNoReply
        }
        return .reply(response)
    }

    // MARK: - Shell fallback

    /// Spawn `clauth daemon` for the dead-banner [Start daemon] button (design
    /// §3.13). Best-effort — returns whether a binary was found to launch. The
    /// spawn is a CHILD of ccsbar (not fully detached); the durable, supervised
    /// relaunch is the operator's LaunchAgent, so this is an in-session relight, not
    /// a substitute for it.
    @discardableResult
    static func startDaemon() -> Bool {
        guard let bin = clauthBinary() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["daemon"]
        do { try proc.run(); return true } catch { return false }
    }

    /// Locate the `clauth` binary: PATH, then the standard cargo bin.
    private static func clauthBinary() -> String? {
        let cargo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo/bin/clauth").path
        for candidate in ["/opt/homebrew/bin/clauth", "/usr/local/bin/clauth", cargo] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The exact `clauth login` argv for a login shape (TABS-1). Pure and
    /// unit-tested — the four CLI shapes ccsbar can spawn:
    /// claude browser (`login [--new] <name>`), codex capture
    /// (`… --codex` — copies the live ~/.codex/auth.json, instant, no browser),
    /// codex browser PKCE (`… --codex --browser`). `browser` is codex-only on the
    /// CLI (a claude login is always a browser flow; bare `--browser` is a usage
    /// error), so it's emitted only alongside `--codex`.
    static func loginArgs(_ name: String, newOnly: Bool, codex: Bool, browser: Bool) -> [String] {
        var args = ["login"]
        if newOnly { args.append("--new") }
        args.append(name)
        if codex {
            args.append("--codex")
            if browser { args.append("--browser") }
        }
        return args
    }

    /// The argv for the session-token capture (CLA-SPLIT): `--yes` because a
    /// non-TTY spawn can never answer the replace-confirm, mirroring `--new`'s
    /// role in the add flow. Pure and unit-tested.
    static func setupTokenArgs(_ name: String) -> [String] {
        ["login", name, "--setup-token", "--yes"]
    }

    /// Pipe a pasted `claude setup-token` mint into
    /// `clauth login <name> --setup-token --yes` — the CLI's non-TTY stdin
    /// path. The token goes ONLY down the pipe (never argv, so never visible
    /// in `ps`; never logged); the CLI validates it authoritatively and owns
    /// the sidecar write. Instant and local — no browser, no socket — so it
    /// works with the daemon up or down, like every other login spawn.
    static func installSetupToken(_ name: String, token: String) async -> CommandOutcome {
        guard let bin = clauthBinary() else { return .unreachable }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = setupTokenArgs(name)
        let stdin = Pipe()
        proc.standardInput = stdin
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandOutcome, Never>) in
            proc.terminationHandler = { p in
                let status = p.terminationStatus
                cont.resume(returning: status == 0
                    ? .ok
                    : .daemonError(code: "cli_failed", message: "clauth login exited \(status)"))
            }
            do {
                try proc.run()
                stdin.fileHandleForWriting.write(Data((token + "\n").utf8))
                stdin.fileHandleForWriting.closeFile()
            } catch {
                // Never started → the termination handler won't fire; resume here once.
                proc.terminationHandler = nil
                cont.resume(returning: .daemonError(
                    code: "cli_failed", message: "could not run clauth: \(error.localizedDescription)"))
            }
        }
    }

    /// Run `clauth login <name>` — the self-contained login flow. Since clauth
    /// v0.8.0 this ONE verb serves BOTH ccsbar login surfaces: a NEW `name` CREATES
    /// the profile, an EXISTING `name` re-authenticates it (clearing its
    /// `auth_broken` flag). TABS-1 adds the codex shapes: `codex: true` captures the
    /// live codex login (instant, no browser); `codex: true, browser: true` mints a
    /// fresh one via the PKCE browser flow. Awaits the process through its
    /// termination handler — no parked thread while the (potentially long) browser
    /// sign-in runs. On exit 0 the CLI has written fresh tokens (and, for a new
    /// name, the profile) to config; the daemon reflects that on its next
    /// status.json write. Works with the daemon up OR down — a pure CLI login, no
    /// socket needed. The caller's in-flight window is bounded by clauth's own
    /// `LOGIN_TIMEOUT_SECS` (180s in `oauth_login.rs`), so no client-side timeout is
    /// needed. Exit 0 → `.ok`; non-zero / timed-out → `.daemonError`; no binary → `.unreachable`.
    /// `newOnly` passes `--new`, pinning CREATE semantics: clauth refuses (exit ≠ 0)
    /// if the name already exists, checked against ITS freshly-loaded config at spawn
    /// time. That is the race-proof collision guard — ccsbar's own pre-check runs on
    /// the last-polled snapshot, so a profile minted out-of-band inside the poll
    /// window would otherwise be silently re-authenticated (non-TTY spawns never see
    /// clauth's confirm prompt).
    ///
    /// `onLink` receives the sign-in URL the CLI announces (codex browser PKCE:
    /// `clauth: opening <url>`), once. `open` hands a URL to whichever running
    /// instance of the default browser LaunchServices picks, and an agent's
    /// headless Chrome is one; the banner offers the link so a sign-in that
    /// opened out of sight can still finish (2026-09-26).
    static func login(
        _ name: String, newOnly: Bool = false, codex: Bool = false, browser: Bool = true,
        onLink: (@Sendable (URL) -> Void)? = nil
    ) async -> CommandOutcome {
        guard let bin = clauthBinary() else { return .unreachable }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = loginArgs(name, newOnly: newOnly, codex: codex, browser: browser)
        let stdout = onLink.map { watchForLoginLink(proc, onLink: $0) }
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandOutcome, Never>) in
            proc.terminationHandler = { p in
                stdout?.fileHandleForReading.readabilityHandler = nil
                let status = p.terminationStatus
                cont.resume(returning: status == 0
                    ? .ok
                    : .daemonError(code: "cli_failed", message: "clauth login exited \(status)"))
            }
            do {
                try proc.run()
            } catch {
                // Never started → the termination handler won't fire; resume here once.
                proc.terminationHandler = nil
                cont.resume(returning: .daemonError(
                    code: "cli_failed", message: "could not run clauth: \(error.localizedDescription)"))
            }
        }
    }

    /// The sign-in URL in one line of `clauth login` stdout, or nil. Only the
    /// codex PKCE announcement counts, and only an https URL: its redirect is a
    /// loopback callback, so the link finishes the sign-in in any browser. Pure
    /// and unit-tested.
    static func loginLink(fromLine line: String) -> URL? {
        let prefix = "clauth: opening "
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        guard let url = URL(string: String(trimmed.dropFirst(prefix.count))),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Pipe `proc`'s stdout and report the first announced sign-in URL. The
    /// pipe is read to the end so the CLI never blocks on a full buffer.
    private static func watchForLoginLink(_ proc: Process, onLink: @escaping @Sendable (URL) -> Void) -> Pipe {
        let pipe = Pipe()
        proc.standardOutput = pipe
        let state = LinkScan()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let url = state.feed(data) else { return }
            onLink(url)
        }
        return pipe
    }

    /// Line assembly for [`watchForLoginLink`]: bytes arrive in arbitrary
    /// chunks, the URL is reported once.
    final class LinkScan: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var reported = false

        func feed(_ data: Data) -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard !reported else { return nil }
            buffer += String(decoding: data, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let url = DaemonClient.loginLink(fromLine: line) {
                    reported = true
                    return url
                }
            }
            return nil
        }
    }

    /// The argv for a profile delete: `--yes` because a non-TTY spawn can never
    /// answer the CLI confirm — the panel's own armed confirm banner is the
    /// deliberate step. NEVER `--force`: a profile with a live `clauth start`
    /// session must keep being refused, and that refusal is surfaced verbatim
    /// rather than overridden from a menu item. Pure and unit-tested.
    static func deleteArgs(_ name: String) -> [String] {
        ["delete", name, "--yes"]
    }

    /// The error copy for a failed `clauth delete`, from its captured stderr.
    /// The WHOLE refusal, newlines flattened — clauth's `resolve_or_bail` emits
    /// two lines ("Error: profile 'x' not found" + "available: …"), and picking
    /// any single line either drops the failure or drops the hint. Empty stderr
    /// falls back to the exit status. Pure and unit-tested.
    static func deleteFailureReason(stderr: String, exitStatus: Int32) -> String {
        let flattened = flattenedLines(stderr)
        return flattened.isEmpty ? "clauth delete exited \(exitStatus)" : flattened
    }

    /// Every non-blank line of a CLI stream, trimmed and joined with " — " — one
    /// banner line that keeps a multi-line refusal whole.
    private static func flattenedLines(_ text: String) -> String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// How long a `clauth delete` may run before the spawn is presumed wedged.
    /// The command is local filesystem work (config rewrite + `remove_dir_all`)
    /// and exits in milliseconds; 30s is generous. The socket path bounds every
    /// blocking call (`ioTimeout`) — this is the same policy for the CLI
    /// spawns whose output we also read (`runCapturing`).
    private static let deleteTimeout: Duration = .seconds(30)

    /// Run `clauth delete <name> --yes` (CLI-only — the daemon socket carries no
    /// delete verb, deliberately: a destructive command wants the CLI's own
    /// guards, not a new socket surface). stderr is captured so a refusal
    /// ("has a live session", "unknown profile") reaches the error banner as
    /// clauth's own words instead of a bare exit code.
    static func deleteProfile(_ name: String) async -> CommandOutcome {
        guard let bin = clauthBinary() else { return .unreachable }
        switch await runCapturing(bin, deleteArgs(name), timeout: deleteTimeout) {
        case .failed(let message):
            return .daemonError(code: "cli_failed", message: "could not run clauth: \(message)")
        case .exited(0, _, _, _):
            return .ok
        case .exited(let status, _, _, let stderr):
            return .daemonError(
                code: "cli_failed",
                message: deleteFailureReason(
                    stderr: String(decoding: stderr, as: UTF8.self), exitStatus: status))
        }
    }

    // MARK: - Use a codex usage-limit reset (CLI-only)

    /// The argv for spending one banked codex usage-limit reset: `--yes`
    /// because a non-TTY spawn can never answer the CLI confirm (clauth
    /// refuses a non-TTY run without it, before any network call) — the
    /// panel's armed banner is the deliberate step. Pure and unit-tested.
    static func useResetArgs(_ name: String) -> [String] {
        ["use-reset", name, "--yes"]
    }

    /// How a `clauth use-reset` spawn resolved. Its own type rather than
    /// `CommandOutcome` because success carries clauth's summary line — the
    /// only place the user learns how many windows reopened and how many
    /// resets remain before the daemon's next poll.
    enum UseResetOutcome: Equatable, Sendable {
        /// Exit 0: a reset was used (or clauth found it already redeemed).
        /// The summary is clauth's first stdout line, display-ready; nil when
        /// stdout said nothing.
        case used(summary: String?)
        /// clauth refused or failed — the message is display-ready.
        case failed(String)
        /// No clauth binary — nothing ran, so nothing was spent.
        case unreachable
    }

    /// Classify a finished `clauth use-reset` run. Exit 0 → `.used` with the
    /// summary; a signal death (the watchdog, or anything else) → the one
    /// outcome clauth never got to report, so it says the reset MAY have gone
    /// through and names `--list` as the check before a retry; any other exit →
    /// clauth's own stderr. Pure and unit-tested.
    static func useResetOutcome(
        name: String, status: Int32, signaled: Bool, stdout: String, stderr: String
    ) -> UseResetOutcome {
        if signaled {
            return .failed("clauth use-reset was stopped before it finished — the reset may or may not"
                + " have gone through. Check `clauth use-reset \(name) --list` before trying again.")
        }
        if status == 0 { return .used(summary: useResetSummary(stdout: stdout)) }
        return .failed(useResetFailureReason(stderr: stderr, exitStatus: status))
    }

    /// clauth's one-line success summary for display: the first non-blank
    /// stdout line with its `clauth: ` prefix stripped and the first letter
    /// raised ("clauth: used a usage-limit reset on 'x': …" → "Used a …").
    /// nil when stdout is blank. Pure and unit-tested.
    static func useResetSummary(stdout: String) -> String? {
        guard let line = stdout.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let prefix = "clauth: "
        return sentenceCased(line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line)
    }

    /// The error copy for a failed `clauth use-reset`: its stderr flattened
    /// the way `deleteFailureReason` does it (a refusal plus its hint stay
    /// together), minus Rust's leading `Error: ` — the banner already says it
    /// is an error. Empty stderr falls back to the exit status. Pure and
    /// unit-tested.
    static func useResetFailureReason(stderr: String, exitStatus: Int32) -> String {
        let flattened = flattenedLines(stderr)
        guard !flattened.isEmpty else { return "clauth use-reset exited \(exitStatus)" }
        let prefix = "Error: "
        return sentenceCased(flattened.hasPrefix(prefix) ? String(flattened.dropFirst(prefix.count)) : flattened)
    }

    /// First character upper-cased — clauth's messages start lower-case after
    /// their prefix, which reads as a fragment at the head of a banner.
    private static func sentenceCased(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Past this a `clauth use-reset` spawn is presumed wedged. clauth bounds
    /// each of its two requests (list, then consume) at ~15s, so a healthy run
    /// finishes well inside it.
    private static let useResetTimeout: Duration = .seconds(60)

    /// Run `clauth use-reset <name> --yes`: clauth lists the account's banked
    /// resets, picks the one expiring soonest, and consumes it. CLI-only, like
    /// delete — the daemon socket carries no verb for it — and it works with
    /// the daemon up or down. Never retried from here: a retry after an
    /// unconfirmed outcome could spend a second reset.
    static func useReset(_ name: String) async -> UseResetOutcome {
        guard let bin = clauthBinary() else { return .unreachable }
        switch await runCapturing(bin, useResetArgs(name), timeout: useResetTimeout) {
        case .failed(let message):
            // Never started, so nothing was spent.
            return .failed("Couldn't run clauth: \(message)")
        case .exited(let status, let signaled, let stdout, let stderr):
            return useResetOutcome(
                name: name, status: status, signaled: signaled,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        }
    }

    // MARK: - Captured spawn (shared by delete and use-reset)

    /// One `clauth` spawn whose output we read: it never started, or it exited
    /// — normally or by a signal, the watchdog's included — with both streams
    /// read to EOF. Internal (with `runCapturing`) so a test can drive the
    /// drain and the watchdog with `/bin/sh` — never with clauth.
    enum Captured: Equatable {
        case failed(String)
        case exited(status: Int32, signaled: Bool, stdout: Data, stderr: Data)
    }

    /// Spawn `clauth <args>` capturing stdout AND stderr, bounded by `timeout`.
    ///
    /// Both pipes are drained CONCURRENTLY with the wait, never only after
    /// exit: a child that fills an OS pipe buffer blocks in `write()` and
    /// never terminates, so a drain that waits for `terminationHandler`
    /// deadlocks — and each caller's in-flight flag is a single global gate,
    /// so one wedged spawn would disable its verb for every account until the
    /// app restarts. A watchdog SIGTERMs the child past `timeout` for the same
    /// reason; the termination handler then fires normally and reports it.
    static func runCapturing(_ bin: String, _ args: [String], timeout: Duration) async -> Captured {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let outEnd = stdout.fileHandleForReading
        let errEnd = stderr.fileHandleForReading
        // Started before the wait so neither pipe can fill unread. Each reaches
        // EOF when its write end closes — on the spawn-failure path that is
        // when `proc` and the pipes release their handles at scope exit.
        let outDrain = Task.detached { outEnd.readDataToEndOfFile() }
        let errDrain = Task.detached { errEnd.readDataToEndOfFile() }

        enum Spawn { case exited(Int32, signaled: Bool), failed(String) }
        let spawn: Spawn = await withCheckedContinuation { cont in
            proc.terminationHandler = {
                cont.resume(returning: .exited(
                    $0.terminationStatus, signaled: $0.terminationReason == .uncaughtSignal))
            }
            do {
                try proc.run()
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if proc.isRunning { proc.terminate() }
                }
            } catch {
                // Never started → the termination handler won't fire; resume here once.
                proc.terminationHandler = nil
                cont.resume(returning: .failed(error.localizedDescription))
            }
        }
        switch spawn {
        case .failed(let message):
            outDrain.cancel()
            errDrain.cancel()
            return .failed(message)
        case .exited(let status, let signaled):
            let out = await outDrain.value
            let err = await errDrain.value
            return .exited(status: status, signaled: signaled, stdout: out, stderr: err)
        }
    }

    /// Run `clauth <args>` and report its outcome by exit status (TECH-11). Blocking
    /// (waits for exit) — only reached from the off-main-actor command path, and a
    /// switch's Keychain write is a couple seconds at most. Exit 0 → `.ok`; non-zero
    /// or spawn failure → `.daemonError`; no binary at all → `.unreachable`.
    private static func shellClauth(_ args: [String]) -> CommandOutcome {
        guard let bin = clauthBinary() else {
            return .unreachable
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
                ? .ok
                : .daemonError(code: "cli_failed", message: "clauth exited \(proc.terminationStatus)")
        } catch {
            return .daemonError(code: "cli_failed", message: "could not run clauth: \(error.localizedDescription)")
        }
    }
}
