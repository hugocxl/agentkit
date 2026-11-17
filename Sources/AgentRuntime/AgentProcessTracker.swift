import Foundation
import os

/// Provider processes a service starts outside conversations, such as model and command
/// discovery. Each stays tracked until it exits, even after its discovery finished with
/// it; shutdown refuses new ones, stops the rest and waits until they exit.
final class AgentProcessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var processes: [UUID: AgentProcess] = [:]
    private struct Launched: Sendable {
        var folder: AgentFolder
        var process: AgentProcess?
    }
    /// The folders its providers run in, and their processes once launched, from before each
    /// launches until it exits, behind a lock never held across a launch or reading a folder.
    private let folders = OSAllocatedUnfairLock<[UUID: Launched]>(initialState: [:])
    /// Reads a launch folder, which may stall on a slow volume; tests stand one in.
    var readFolder: @Sendable (String) -> AgentFolder = { AgentFolder($0) }
    /// Tests hold a launch here, once its folder is reserved and before its process starts.
    var onReserved: (@Sendable () -> Void)?

    /// Starts a provider unless shutdown began.
    func launch(_ launch: AgentProcess.Launch, directory: String, onLine: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32, String) -> Void) throws -> AgentProcess {
        let id = UUID()
        // One physical folder, as a conversation's provider has, so a revert there finds it.
        let launchDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        let folder = readFolder(launchDirectory)
        folders.withLock { $0[id] = Launched(folder: folder) }
        onReserved?()
        // Launching under the lock keeps shutdown from missing a provider that starts meanwhile.
        lock.lock()
        defer { lock.unlock() }
        do {
            guard !closed else { throw AgentRuntimeError("The agent service is shutting down.") }
            let process = try AgentProcess(launch: launch, directory: launchDirectory, onLine: onLine) { [weak self] status, errors in
                self?.lock.withLock { _ = self?.processes.removeValue(forKey: id) }
                self?.folders.withLock { _ = $0.removeValue(forKey: id) }
                onExit(status, errors)
            }
            processes[id] = process
            folders.withLock { $0[id]?.process = process }
            return process
        } catch {
            folders.withLock { _ = $0.removeValue(forKey: id) }
            throw error
        }
    }

    /// Whether one of its providers may change files `scope` restores: launching, running, or
    /// stopping and not yet exited, there, inside it or around it.
    func mayRun(in scope: AgentRevertScope) -> Bool {
        folders.withLock {
            $0.values.contains { launched in
                guard let process = launched.process else { return scope.holds(launched.folder) }
                // Until it has exited, which its output, held open by a helper it started, may outlast.
                return process.isRunning && scope.holds(launched.folder, process: process.processIdentifier)
            }
        }
    }

    /// Its providers' processes that may still run.
    func processIDs() -> [Int32] {
        folders.withLock { $0.values.compactMap { $0.process?.isRunning == true ? $0.process?.processIdentifier : nil } }
    }

    var running: Int { lock.withLock { processes.count } }

    func shutdown() {
        let running = lock.withLock { () -> [AgentProcess] in
            closed = true
            return Array(processes.values)
        }
        DispatchQueue.concurrentPerform(iterations: running.count) { index in
            running[index].stop()
            running[index].waitForExit()
        }
    }
}
