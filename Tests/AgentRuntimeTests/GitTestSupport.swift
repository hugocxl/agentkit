import Foundation
import AgentCore
@testable import AgentRuntime

final class GitTestRepo {
    let path: String
    init(commit: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-git-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.resolvingSymlinksInPath().path
        try run("init", "-b", "main")
        try run("config", "user.name", "Test")
        try run("config", "user.email", "test@example.invalid")
        try run("config", "commit.gpgsign", "false")
        if commit { try run("commit", "--allow-empty", "-m", "initial") }
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    @discardableResult
    func run(_ arguments: String...) throws -> String {
        let output = try ProcessRunner.run("/usr/bin/git", arguments, directory: path,
                                           environment: GitCommand.environment(), timeout: 30)
        guard output.succeeded else { throw ModelError(output.stderrText) }
        return output.stdoutText
    }
    @discardableResult
    func commit(_ message: String) throws -> String {
        try run("add", "-A")
        try run("commit", "-m", message)
        return try run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
