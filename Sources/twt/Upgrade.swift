import ArgumentParser
import Foundation
import TreepoolCore

struct Upgrade: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upgrade the Treepool CLI to the latest release."
    )

    @Option(name: .long, help: "Install a specific release, such as 0.2.1.")
    var to: String?

    func run() throws {
        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("Could not locate the running CLI executable.")
        }
        do {
            try ReleaseUpgrade.install(
                executable: executable,
                version: to,
                environment: ProcessInfo.processInfo.environment
            )
        } catch TreepoolError.git(let message) {
            throw ValidationError("Upgrade failed: \(message)")
        }
        print("✓ Treepool upgraded")
    }
}

enum ReleaseUpgrade {
    static func install(executable: URL, version: String?, environment: [String: String]) throws {
        var environment = environment
        let repository = environment["TREEPOOL_REPOSITORY"] ?? "tokudayo/treepool"
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({
            $0 != "." && $0 != ".." && $0.range(of: "\\A[A-Za-z0-9_.-]+\\z", options: .regularExpression) != nil
        }) else {
            throw ValidationError("TREEPOOL_REPOSITORY must be an owner/repository name.")
        }
        if let version {
            guard version.range(of: "\\Av?[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil else {
                throw ValidationError("Use --to X.Y.Z to select a release.")
            }
            environment["TREEPOOL_VERSION"] = version.hasPrefix("v") ? String(version.dropFirst()) : version
        }
        if environment["TREEPOOL_BIN_DIR", default: ""].isEmpty {
            let resolved = executable.resolvingSymlinksInPath()
            guard resolved.lastPathComponent == "twt" else {
                throw ValidationError("Could not locate the installed twt; set TREEPOOL_BIN_DIR explicitly.")
            }
            environment["TREEPOOL_BIN_DIR"] = resolved.deletingLastPathComponent().path
        }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("twt-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let installer = staging.appendingPathComponent("install-release.sh")
        let download = try ProcessRunner.run(
            "curl", [
                "--fail", "--silent", "--show-error", "--location",
                "--connect-timeout", "15", "--max-time", "60",
                "--proto", "=https", "--proto-redir", "=https",
                "--output", installer.path,
                "https://raw.githubusercontent.com/\(repository)/main/scripts/install-release.sh",
            ], environment: environment, allowFailure: true
        )
        guard download.status == 0 else {
            throw ValidationError("Could not download the release installer: \(download.stderr)")
        }
        let result = try ProcessRunner.run(
            "/bin/bash", [installer.path], environment: environment,
            streamOutput: true, allowFailure: true
        )
        guard result.status == 0 else { throw ExitCode(result.status) }
    }
}
