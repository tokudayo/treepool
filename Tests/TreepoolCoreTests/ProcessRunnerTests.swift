import Foundation
import Testing
@testable import TreepoolCore

@Suite("Process completion")
struct ProcessRunnerTests {
    @Test
    func capturesLargeOutputOnBothStreamsBeforeReturning() throws {
        let result = try ProcessRunner.run("/bin/sh", ["-c", """
            i=0
            while [ "$i" -lt 8192 ]; do
              printf 'stdout-line\n'
              printf 'stderr-line\n' >&2
              i=$((i + 1))
            done
            """])
        #expect(result.status == 0)
        #expect(result.stdout.split(separator: "\n").count == 8192)
        #expect(result.stderr.split(separator: "\n").count == 8192)
    }

    @Test
    func retainsNonzeroExitStatusAndDiagnostics() throws {
        let result = try ProcessRunner.run(
            "/bin/sh", ["-c", "printf output; printf failure >&2; exit 7"],
            allowFailure: true
        )
        #expect(result.status == 7)
        #expect(result.stdout == "output")
        #expect(result.stderr == "failure")
        #expect(throws: TreepoolError.self) {
            try ProcessRunner.run("/bin/sh", ["-c", "printf failure >&2; exit 7"])
        }
    }

    @Test
    func streamingCommandsWaitForCompletionAndPropagateFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("twt-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ProcessRunner.run(
            "/bin/sh", ["-c", "sleep 0.05; printf finished > completed; exit 7"],
            directory: root, streamOutput: true, allowFailure: true
        )
        #expect(result.status == 7)
        #expect(try String(contentsOf: root.appendingPathComponent("completed"), encoding: .utf8) == "finished")
        #expect(throws: TreepoolError.self) {
            try ProcessRunner.run("/bin/sh", ["-c", "exit 7"], streamOutput: true)
        }
    }

    @Test
    func launchFailureThrowsWithoutWaitingForTermination() throws {
        #expect(throws: TreepoolError.self) {
            try ProcessRunner.run("/this-path-does-not-exist/twt-command", [])
        }
    }
}
