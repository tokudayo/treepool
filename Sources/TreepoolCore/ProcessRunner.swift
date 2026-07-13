import Foundation

public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
}

public enum ProcessRunner {
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil,
        allowFailure: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("twt-process-\(UUID().uuidString)")
        let stdoutURL = temporary.appendingPathExtension("stdout")
        let stderrURL = temporary.appendingPathExtension("stderr")
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: attributes)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: attributes)
        guard let stdout = FileHandle(forWritingAtPath: stdoutURL.path),
              let stderr = FileHandle(forWritingAtPath: stderrURL.path) else {
            throw TreepoolError.git("could not create process output files")
        }
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.executableURL = executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw TreepoolError.git("\(executable): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try? stdout.close()
        try? stderr.close()
        let output = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        let error = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        let result = CommandResult(
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: error.trimmingCharacters(in: .whitespacesAndNewlines),
            status: process.terminationStatus
        )
        if !allowFailure && result.status != 0 {
            throw TreepoolError.git(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }
}
