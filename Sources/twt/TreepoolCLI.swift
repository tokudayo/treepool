import ArgumentParser
import Foundation
import TreepoolCore

struct JSONEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = 1
    let command: String
    let ok = true
    let data: Value
    let warnings: [String]
}

struct JSONErrorEnvelope: Encodable {
    struct Failure: Encodable {
        let code: String
        let message: String
    }

    let schemaVersion = 1
    let command: String
    let ok = false
    let error: Failure
    let warnings: [String] = []
}

enum CLI {
    static let manager = TreepoolManager()

    static var cwd: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var homeDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func context() throws -> RepositoryContext {
        try manager.context(at: cwd)
    }

    static func outputJSON<T: Encodable>(
        _ value: T,
        command: String,
        warnings: [String] = []
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let envelope = JSONEnvelope(command: command, data: value, warnings: warnings)
        print(String(decoding: try encoder.encode(envelope), as: UTF8.self))
    }

    static func run(json: Bool = false, command: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as TreepoolError {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let envelope = JSONErrorEnvelope(
                    command: command,
                    error: .init(code: error.code, message: error.description)
                )
                let data = (try? encoder.encode(envelope)) ?? Data()
                FileHandle.standardError.write(data + Data("\n".utf8))
            } else {
                FileHandle.standardError.write(Data("twt: \(error.description)\n".utf8))
                if let suggestion = error.suggestion {
                    FileHandle.standardError.write(Data("Hint: \(suggestion)\n".utf8))
                }
            }
            throw ExitCode(error.exitCode)
        }
    }

    static func printSlot(_ slot: WorktreeInfo) {
        print("✓ \(slot.name) ready")
        print("  Branch: \(slot.branch ?? "(detached HEAD)")")
        print("  Path:   \(slot.path)")
    }

    static func printList(_ items: [WorktreeInfo]) {
        let nameWidth = max(4, items.map(\.name.count).max() ?? 4)
        let branchWidth = max(6, items.map { ($0.branch ?? "(detached)").count }.max() ?? 6)
        print(
            pad("SLOT", to: nameWidth) + "  "
                + pad("BRANCH", to: branchWidth) + "  STATE     PATH"
        )
        for item in items {
            let state = item.clean ? (item.detached ? "idle" : "active") : "dirty"
            print(
                pad(item.name, to: nameWidth) + "  "
                    + pad(item.branch ?? "(detached)", to: branchWidth) + "  "
                    + pad(state, to: 8) + "  "
                    + abbreviateHome(item.path)
            )
        }
    }

    static func printReconcile(_ result: PoolReconcileResult, command: String) {
        let prefix = result.dryRun ? "Would" : "Did"
        print("✓ \(command) complete")
        print("  \(prefix) create: \(result.created.count)")
        print("  \(prefix) repair: \(result.repaired.count)")
        print("  Retained:         \(result.retained.count)")
        print("  Extras untouched: \(result.extras.count)")
        for warning in result.warnings { print("  Warning: \(warning)") }
    }

    private static func pad(_ value: String, to width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized == home || normalized.hasPrefix(home + "/") else { return path }
        return "~" + normalized.dropFirst(home.count)
    }
}

@main
struct Treepool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "twt",
        abstract: "A warm-pool Git worktree manager.",
        version: TreepoolBuildVersion.value,
        subcommands: [
            Init.self, Setup.self, Repair.self, New.self, SwitchBranch.self,
            List.self, Release.self, Config.self, Uninstall.self,
        ]
    )
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a repository-local Treepool profile."
    )

    @Option(name: .long, help: "Number of warm worktree slots.")
    var slots = 4

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "init") {
            let context = try CLI.manager.initialize(at: CLI.cwd, slotCount: slots)
            if json {
                try CLI.outputJSON(context.config, command: "init")
            } else {
                print("✓ Created \(context.mainRoot.appendingPathComponent(".twt.json").path)")
                print("  Base branch: (not set; --from is required for 'twt new')")
                print("  Pool slots:  \(context.config.pool.size) (created)")
            }
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create missing pool slots from the existing .twt.json policy."
    )

    @Flag(name: .long, help: "Report changes without creating worktrees.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "setup") {
            let result = try CLI.manager.setup(in: CLI.context(), dryRun: dryRun)
            if json { try CLI.outputJSON(result, command: "setup", warnings: result.warnings) }
            else { CLI.printReconcile(result, command: "Setup") }
        }
    }
}

struct Repair: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Repair missing configured slots without touching unrelated worktrees."
    )

    @Flag(name: .long, help: "Report changes without repairing worktrees.")
    var dryRun = false

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "repair") {
            let result = try CLI.manager.repair(in: CLI.context(), dryRun: dryRun)
            if json { try CLI.outputJSON(result, command: "repair", warnings: result.warnings) }
            else { CLI.printReconcile(result, command: "Repair") }
        }
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a branch in an idle slot."
    )

    @Argument(help: "New branch name.")
    var branch: String

    @Option(name: .long, help: "Ref from which to create the branch. Defaults to baseBranch.")
    var from: String?

    @Option(name: .long, help: "Slot name or path to use. Defaults to the oldest idle slot.")
    var slot: String?

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "new") {
            let context = try CLI.context()
            let base = (from ?? context.config.baseBranch)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                throw TreepoolError.invalidConfig(
                    "baseBranch is empty; pass '--from REF' to 'twt new'"
                )
            }
            let selectedSlot = try CLI.manager.createBranch(
                branch, from: base, in: context, slot: slot
            )
            if json { try CLI.outputJSON(selectedSlot, command: "new") }
            else { CLI.printSlot(selectedSlot) }
        }
    }
}

struct SwitchBranch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch to an existing branch in an idle slot."
    )

    @Argument(help: "Local or remote branch name.")
    var branch: String

    @Option(name: .long, help: "Slot name or path to use. Defaults to the oldest idle slot.")
    var slot: String?

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "switch") {
            let selectedSlot = try CLI.manager.switchBranch(
                branch, in: CLI.context(), slot: slot
            )
            if json { try CLI.outputJSON(selectedSlot, command: "switch") }
            else { CLI.printSlot(selectedSlot) }
        }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show repository worktrees and pool state."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "list") {
            let items = try CLI.manager.list(in: CLI.context())
            if json { try CLI.outputJSON(items, command: "list") }
            else { CLI.printList(items) }
        }
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Return a clean slot to the pool without deleting its branch."
    )

    @Argument(help: "Slot, branch, or partial name. Defaults to the current managed slot.")
    var query: String?

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        try CLI.run(json: json, command: "release") {
            let context = try CLI.context()
            let slot = if let query {
                try CLI.manager.release(query, in: context)
            } else {
                try CLI.manager.releaseCurrent(at: CLI.cwd, in: context)
            }
            if json { try CLI.outputJSON(slot, command: "release") }
            else {
                print("✓ \(slot.name) returned to the pool")
                print("  Branch preserved; slot is detached at \(slot.head.prefix(10))")
            }
        }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove Treepool while preserving repository worktrees and configuration."
    )

    @Flag(name: .long, help: "Also remove Treepool skill files that have been modified.")
    var force = false

    func run() throws {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = CLI.homeDirectory

        func directory(_ variable: String, default defaultURL: URL) -> URL {
            guard let value = environment[variable], !value.isEmpty else { return defaultURL }
            return URL(fileURLWithPath: value).standardizedFileURL
        }

        let binDirectory = directory(
            "TREEPOOL_BIN_DIR",
            default: home.appendingPathComponent(".local/bin")
        )
        let zshDirectory = directory(
            "TREEPOOL_COMPLETION_DIR",
            default: home.appendingPathComponent(".local/share/zsh/site-functions")
        )
        let bashDirectory = directory(
            "TREEPOOL_BASH_COMPLETION_DIR",
            default: home.appendingPathComponent(".local/share/bash-completion/completions")
        )
        let fishDirectory = directory(
            "TREEPOOL_FISH_COMPLETION_DIR",
            default: home.appendingPathComponent(".config/fish/completions")
        )

        var targets = [
            zshDirectory.appendingPathComponent("_twt"),
            bashDirectory.appendingPathComponent("twt"),
            fishDirectory.appendingPathComponent("twt.fish"),
        ]
        let skillTargets = SkillTarget.all(in: home).map(\.path)
        #if os(macOS)
        let appDirectory = directory(
            "TREEPOOL_APP_DIR",
            default: home.appendingPathComponent("Applications")
        )
        targets.append(appDirectory.appendingPathComponent("Treepool.app"))
        #endif
        let binaryTarget = binDirectory.appendingPathComponent("twt")

        var removed: [String] = []
        var preserved: [String] = []
        // Remove the running executable last. Unix keeps the process alive until it exits.
        for target in targets + skillTargets + [binaryTarget] {
            let exists = fileManager.fileExists(atPath: target.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil
            guard exists else { continue }
            if skillTargets.contains(target), !force,
               (try? String(contentsOf: target, encoding: .utf8)) != WorktreeSkill.contents {
                preserved.append(target.path)
                continue
            }
            try fileManager.removeItem(at: target)
            removed.append(target.path)
            let parent = target.deletingLastPathComponent()
            if target.lastPathComponent == "SKILL.md",
               (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try fileManager.removeItem(at: parent)
            }
        }

        print("✓ Treepool uninstalled")
        if removed.isEmpty {
            print("  No installed files were found.")
        } else {
            for path in removed { print("  Removed: \(path)") }
        }
        for path in preserved {
            print("  Preserved modified skill: \(path)")
        }
        if !preserved.isEmpty {
            print("  Remove preserved skills manually if they are no longer needed.")
        }
        print("  Repository worktrees and configuration were left untouched.")
    }
}

private struct SkillTarget {
    let harness: String
    let path: URL

    static func all(in home: URL) -> [SkillTarget] {
        [
            .init(harness: "Codex", path: home.appending(path: ".codex/skills/use-treepool-worktrees/SKILL.md")),
            .init(harness: "Claude Code", path: home.appending(path: ".claude/skills/use-treepool-worktrees/SKILL.md")),
            .init(harness: "OpenCode", path: home.appending(path: ".config/opencode/skills/use-treepool-worktrees/SKILL.md")),
            .init(harness: "Pi", path: home.appending(path: ".pi/agent/skills/use-treepool-worktrees/SKILL.md")),
        ]
    }

    var state: String {
        guard exists else { return "not installed" }
        guard (try? String(contentsOf: path, encoding: .utf8)) == WorktreeSkill.contents else {
            return "modified"
        }
        return "current"
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Treepool workflow guidance for coding-agent harnesses."
    )

    @Flag(name: .long, help: "Install for OpenAI Codex.")
    var codex = false

    @Flag(name: .customLong("claude-code"), help: "Install for Claude Code.")
    var claudeCode = false

    @Flag(name: .long, help: "Install for OpenCode.")
    var opencode = false

    @Flag(name: .long, help: "Install for Pi.")
    var pi = false

    @Flag(name: .long, help: "Replace or remove a modified Treepool skill document.")
    var force = false

    @Flag(name: .long, help: "Remove guidance for the selected harness.")
    var remove = false

    @Flag(name: .long, help: "Show installed guidance without changing it.")
    var show = false

    @Flag(name: .customLong("dry-run"), help: "Preview the requested change.")
    var dryRun = false

    mutating func validate() throws {
        let count = [codex, claudeCode, opencode, pi].filter({ $0 }).count
        if show {
            guard count <= 1, !remove, !dryRun, !force else {
                throw ValidationError("Use --show alone or with exactly one harness.")
            }
        } else if count != 1 {
            throw ValidationError("Choose exactly one harness: --codex, --claude-code, --opencode, or --pi.")
        }
    }

    func run() throws {
        let home = CLI.homeDirectory
        let targets = SkillTarget.all(in: home)

        if show {
            let shown = selectedTarget(from: targets).map { [$0] } ?? targets
            for target in shown {
                print("\(target.harness): \(target.state)")
                print("  \(target.path.path)")
            }
            return
        }

        guard let target = selectedTarget(from: targets) else {
            throw ValidationError("Choose a harness.")
        }

        let exists = target.exists
        let current = exists
            && (try? String(contentsOf: target.path, encoding: .utf8)) == WorktreeSkill.contents

        if remove {
            guard exists else {
                print("✓ Treepool workflow guidance for \(target.harness) is not installed")
                return
            }
            if !current, !force {
                throw ValidationError(
                    "\(target.path.path) was modified; use --force to remove it."
                )
            }
            if dryRun {
                print("Would remove Treepool workflow guidance for \(target.harness)")
                print("  Path: \(target.path.path)")
                return
            }
            try FileManager.default.removeItem(at: target.path)
            let parent = target.path.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try FileManager.default.removeItem(at: parent)
            }
            print("✓ Removed Treepool workflow guidance for \(target.harness)")
            return
        }

        if current {
            print("✓ Treepool workflow guidance for \(target.harness) is already current")
            print("  Path: \(target.path.path)")
            return
        }
        if exists, !force {
            throw ValidationError(
                "\(target.path.path) was modified. Re-run with --force to replace it."
            )
        }

        if dryRun {
            print("Would \(exists ? "replace" : "install") Treepool workflow guidance for \(target.harness)")
            print("  Path: \(target.path.path)")
            return
        }

        try FileManager.default.createDirectory(
            at: target.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WorktreeSkill.contents.write(to: target.path, atomically: true, encoding: .utf8)
        print("✓ \(exists ? "Updated" : "Installed") Treepool workflow guidance for \(target.harness)")
        print("  Path: \(target.path.path)")
    }

    private func selectedTarget(from targets: [SkillTarget]) -> SkillTarget? {
        if codex { return targets[0] }
        if claudeCode { return targets[1] }
        if opencode { return targets[2] }
        if pi { return targets[3] }
        return nil
    }
}
