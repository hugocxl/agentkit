import AgentCore
import Darwin
import Foundation
import os

/// NDJSON transport. Readers drain both pipes independently; stdout EOF precedes exit delivery.
internal final class AgentProcess: @unchecked Sendable {
    // Eight 10 MiB tool images expand to about 107 MiB of base64, plus metadata.
    static let maxLineBytes = 128 * 1024 * 1024
    /// How long a stopped provider has before it is killed; tests stretch it.
    nonisolated(unsafe) static var stopGrace: TimeInterval = 1
    /// Tests learn here, with the input held, that a write waits for a provider to read.
    var onWriteWaiting: (@Sendable () -> Void)?
    struct Launch: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var stopped = false
    private let lock = NSLock()
    /// Set when it ended the provider itself, as for a line past the limit.
    private let ended = OSAllocatedUnfairLock(initialState: false)
    /// Set once it is asked to stop, read without the input lock a write may hold for seconds.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)

    /// Whether it was asked to stop, by its runtime or by itself, while it may still run:
    /// until it has exited it may still change files.
    var isStopping: Bool { (stopRequested.withLock { $0 } || ended.withLock { $0 }) && process.isRunning }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path(inherited: environment["PATH"] ?? "", home: NSHomeDirectory())
        return environment
    }

    /// macOS's own tool directories, which hold stale tools such as Python 3.9.
    static let systemPaths: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Builds the agent PATH. System directories go last so Homebrew and version-manager tools
    /// win over macOS's own (`python3` must not resolve to `/usr/bin/python3` in git hooks).
    static func path(inherited: String, home: String) -> String {
        let entries = inherited.split(separator: ":").map(String.init)
        var paths = entries.filter { !systemPaths.contains($0) }
        paths += ["\(home)/.local/bin", "\(home)/.npm-global/bin",
                  "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
                  "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims", "\(home)/.yarn/bin",
                  "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        // GUI-launched servers often lack the Node version manager's shell PATH.
        for (root, suffix) in [("\(home)/.nvm/versions/node", "bin"),
                               ("\(home)/.local/share/fnm/node-versions", "installation/bin")] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/\(suffix)" }
        }
        paths += entries.filter { systemPaths.contains($0) } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static func resolve(_ name: String, environment: [String: String]) throws -> URL {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        let kind = AgentChatProvider.allCases.first { $0.spec.executable == name }
        let install = " Install \(kind?.name ?? name)" + (kind?.spec.installCommand.map { " with `\($0)`," } ?? ",")
        throw AgentRuntimeError("\(name) was not found.\(install) sign in, and make sure it is on PATH (for example ~/.local/bin or /opt/homebrew/bin).")
    }

    init(launch: Launch, directory: String, maxLineBytes: Int = AgentProcess.maxLineBytes,
         onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw AgentRuntimeError("Could not configure nonblocking agent input: \(String(cString: strerror(errno)))")
        }
        try process.run()
        // Parent copies must not keep the child's pipe ends alive.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stderr = AgentProcessStderr()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        Thread.detachNewThread { [errors] in
            defer { try? errors.fileHandleForReading.close(); stderrDone.leave() }
            while let chunk = Self.readAvailable(errors.fileHandleForReading.fileDescriptor), !chunk.isEmpty {
                stderr.append(chunk)
            }
        }
        Thread.detachNewThread { [output, process, ended] in
            var buffer = Data()
            var searchedThrough = 0
            var oversized = false
            readLoop: while let chunk = Self.readAvailable(output.fileHandleForReading.fileDescriptor), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer[buffer.index(buffer.startIndex, offsetBy: searchedThrough)...].firstIndex(of: 10) {
                    let length = buffer.distance(from: buffer.startIndex, to: newline)
                    if length > maxLineBytes {
                        oversized = true
                        ended.withLock { $0 = true }
                        Self.end(process)
                        break readLoop
                    }
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    searchedThrough = 0
                    if !line.isEmpty { onLine(line) }
                }
                searchedThrough = buffer.count
                if buffer.count > maxLineBytes {
                    oversized = true
                    ended.withLock { $0 = true }
                    Self.end(process)
                    break
                }
            }
            if !oversized && !buffer.isEmpty { onLine(buffer) }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            // Do not wait for descendants that inherited stderr indefinitely.
            _ = stderrDone.wait(timeout: .now() + 0.5)
            onExit(process.terminationStatus, stderr.text)
        }
    }

    private static func readAvailable(_ descriptor: Int32) -> Data? {
        // FileHandle.read(upToCount:) may try to fill the requested count on pipes,
        // starving low-volume interactive responses until another turn writes bytes.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR { return nil }
        }
    }

    func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count < AgentLimits.maxFrame else {
            throw AgentRuntimeError("Agent input exceeds the maximum frame size. Remove attachments or use smaller files.")
        }
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw AgentRuntimeError("Agent process is closed.") }
        let descriptor = input.fileHandleForWriting.fileDescriptor
        // A CLI can remain alive while no longer reading stdin. Never let its pipe
        // block the runtime queue (and therefore stop/interrupt/timeouts) indefinitely.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw AgentRuntimeError("Agent stopped reading input; submission timed out. Reopen the agent pane to resume.")
                }
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(bytes.count - offset, 16_384))
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw AgentRuntimeError("Could not write agent input: \(String(cString: strerror(errno)))")
                }
                onWriteWaiting?()
                var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&readiness, 1, 50)
                if result < 0, errno != EINTR {
                    throw AgentRuntimeError("Could not wait for agent input: \(String(cString: strerror(errno)))")
                }
                if readiness.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw AgentRuntimeError("Agent closed its input pipe.")
                }
            }
        }
    }

    func stop() {
        stopRequested.withLock { $0 = true }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        Self.end(process)
    }

    /// Asks `process` to end, and kills it once `stopGrace` has passed if it took no notice.
    private static func end(_ process: Process) {
        process.terminate()
        // Foundation's reader thread always waits/reaps, including escalation.
        DispatchQueue.global().asyncAfter(deadline: .now() + stopGrace) { [process] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    var isRunning: Bool { process.isRunning }

    /// Its process's identifier, once launched.
    var processIdentifier: Int32 { process.processIdentifier }

    /// Where a process works now, as the system knows it.
    enum WorkingDirectory: Equatable {
        /// The folder the system names, checked to be the one it works in.
        case folder(String)
        /// A name that can't be trusted, such as a deep folder's cut short or a removed one's.
        case unknown
    }

    /// Where process `pid` works now, wherever it launched; nil once it is gone.
    static func workingDirectory(of pid: Int32) -> WorkingDirectory? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return kill(pid, 0) == -1 && errno == ESRCH ? nil : .unknown
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // The system keeps only a long path's tail, and a removed folder's old name, which
        // another folder may have taken since.
        var status = stat()
        guard path.hasPrefix("/"), stat(path, &status) == 0,
              UInt32(bitPattern: status.st_dev) == info.pvi_cdir.vip_vi.vi_stat.vst_dev,
              status.st_ino == info.pvi_cdir.vip_vi.vi_stat.vst_ino else { return .unknown }
        return .folder(path)
    }

    /// Waits until the stopped provider has exited, killing it once `grace` passes, so a
    /// provider that ignores the request can't outlive a host about to exit and take the
    /// scheduled escalation with it.
    func waitForExit(grace: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        let reaped = Date().addingTimeInterval(1)
        while process.isRunning, Date() < reaped { usleep(10_000) }
    }

    deinit { stop() }
}

private final class AgentProcessStderr: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 8_192 { data = Data(data.suffix(8_192)) }
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
