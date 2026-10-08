import ArgumentParser
import Foundation
import Testing
@testable import twt

@Suite("CLI upgrade")
struct UpgradeTests {
    @Test
    func upgradesRunningInstallationAndPreservesRepositoryFiles() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        let config = fixture.root.appendingPathComponent(".twt.json")
        try Data("repository policy".utf8).write(to: config)
        try ReleaseUpgrade.install(executable: fixture.executable, version: nil, environment: fixture.environment)
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "new CLI\n")
        #expect(try String(contentsOf: config, encoding: .utf8) == "repository policy")
        #expect(try fixture.receipt() == "latest")
        for name in ["zsh/_twt", "bash/twt", "fish/twt.fish"] {
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
        }
    }

    @Test
    func followsExecutableSymlinkAndNormalizesPinnedVersion() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        let alias = fixture.root.appendingPathComponent("twt-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.executable)
        try ReleaseUpgrade.install(executable: alias, version: "v0.2.1", environment: fixture.environment)
        #expect(try fixture.receipt() == "0.2.1")
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "new CLI\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == fixture.executable.path)
    }

    @Test
    func explicitInstallDirectoryOverridesRunningLocation() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("custom-bin")
        fixture.environment["TREEPOOL_BIN_DIR"] = target.path
        try ReleaseUpgrade.install(executable: fixture.executable, version: "0.2.1", environment: fixture.environment)
        #expect(try String(contentsOf: target.appendingPathComponent("twt"), encoding: .utf8) == "new CLI\n")
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "old CLI\n")
    }

    @Test
    func invalidInputsFailBeforeDownloading() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        #expect(throws: ValidationError.self) {
            try ReleaseUpgrade.install(executable: fixture.executable, version: "bad;version", environment: fixture.environment)
        }
        #expect(throws: ValidationError.self) {
            try ReleaseUpgrade.install(executable: fixture.executable, version: "0.2.1\n", environment: fixture.environment)
        }
        fixture.environment["TREEPOOL_REPOSITORY"] = "../repo"
        #expect(throws: ValidationError.self) {
            try ReleaseUpgrade.install(executable: fixture.executable, version: nil, environment: fixture.environment)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("downloaded").path))
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "old CLI\n")
    }

    @Test
    func downloadFailureDoesNotRunInstaller() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        fixture.environment["TWT_TEST_CURL_STATUS"] = "22"
        #expect(throws: ValidationError.self) {
            try ReleaseUpgrade.install(executable: fixture.executable, version: nil, environment: fixture.environment)
        }
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "old CLI\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("receipt").path))
    }

    @Test
    func installerFailurePropagatesItsExitCode() throws {
        let fixture = try UpgradeFixture(); defer { fixture.cleanup() }
        fixture.environment["TWT_TEST_INSTALLER_STATUS"] = "17"
        #expect(throws: ExitCode(17)) {
            try ReleaseUpgrade.install(executable: fixture.executable, version: nil, environment: fixture.environment)
        }
        #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "old CLI\n")
    }

    @Test
    func parsesUpgradeCommandAndPinnedRelease() throws {
        let command = try Upgrade.parse(["--to", "0.2.1"])
        #expect(command.to == "0.2.1")
    }
}

private final class UpgradeFixture {
    let root: URL
    let executable: URL
    var environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("twt-upgrade-test-\(UUID().uuidString)")
        let tools = root.appendingPathComponent("tools")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        executable = bin.appendingPathComponent("twt")
        try Data("old CLI\n".utf8).write(to: executable)
        let installer = root.appendingPathComponent("installer.sh")
        try Data(#"""
            #!/bin/bash
            set -euo pipefail
            if [[ "${TWT_TEST_INSTALLER_STATUS:-0}" != 0 ]]; then exit "$TWT_TEST_INSTALLER_STATUS"; fi
            mkdir -p "$TREEPOOL_BIN_DIR" "$TREEPOOL_COMPLETION_DIR" "$TREEPOOL_BASH_COMPLETION_DIR" "$TREEPOOL_FISH_COMPLETION_DIR"
            printf 'new CLI\n' > "$TREEPOOL_BIN_DIR/.twt.new"
            mv "$TREEPOOL_BIN_DIR/.twt.new" "$TREEPOOL_BIN_DIR/twt"
            touch "$TREEPOOL_COMPLETION_DIR/_twt" "$TREEPOOL_BASH_COMPLETION_DIR/twt" "$TREEPOOL_FISH_COMPLETION_DIR/twt.fish"
            printf '%s' "${TREEPOOL_VERSION:-latest}" > "$TWT_TEST_ROOT/receipt"
            """#.utf8).write(to: installer)
        let curl = tools.appendingPathComponent("curl")
        try Data(#"""
            #!/bin/sh
            printf downloaded > "$TWT_TEST_ROOT/downloaded"
            if [ "${TWT_TEST_CURL_STATUS:-0}" != 0 ]; then
              printf 'download failed\n' >&2
              exit "$TWT_TEST_CURL_STATUS"
            fi
            while [ "$#" -gt 0 ]; do
              if [ "$1" = --output ]; then output="$2"; shift; fi
              shift
            done
            cp "$TWT_TEST_INSTALLER" "$output"
            """#.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        environment = ProcessInfo.processInfo.environment
        for key in ["TREEPOOL_BIN_DIR", "TREEPOOL_VERSION", "TREEPOOL_REPOSITORY"] { environment.removeValue(forKey: key) }
        environment["PATH"] = tools.path + ":/usr/bin:/bin"
        environment["TWT_TEST_ROOT"] = root.path
        environment["TWT_TEST_INSTALLER"] = installer.path
        environment["TREEPOOL_COMPLETION_DIR"] = root.appendingPathComponent("zsh").path
        environment["TREEPOOL_BASH_COMPLETION_DIR"] = root.appendingPathComponent("bash").path
        environment["TREEPOOL_FISH_COMPLETION_DIR"] = root.appendingPathComponent("fish").path
    }

    func receipt() throws -> String {
        try String(contentsOf: root.appendingPathComponent("receipt"), encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
