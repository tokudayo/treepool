import Foundation

extension TreepoolManager {
    func loadState(_ context: RepositoryContext) throws -> RuntimeState {
        let url = context.stateDirectory.appendingPathComponent("state.json")
        guard fileManager.fileExists(atPath: url.path) else { return RuntimeState() }
        do {
            return try makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: url))
        } catch {
            throw TreepoolError.invalidConfig("runtime state: \(error.localizedDescription)")
        }
    }

    func saveState(_ state: RuntimeState, _ context: RepositoryContext) throws {
        try fileManager.createDirectory(at: context.stateDirectory, withIntermediateDirectories: true)
        try makeEncoder().encode(state).write(
            to: context.stateDirectory.appendingPathComponent("state.json"),
            options: .atomic
        )
    }

    func acquireLock(_ context: RepositoryContext) throws -> RepositoryLock {
        try RepositoryLock(url: context.stateDirectory.appendingPathComponent("operation.lock"))
    }

    func poolRoot(_ context: RepositoryContext) -> URL {
        if context.config.pool.root.hasPrefix("/") {
            return URL(fileURLWithPath: context.config.pool.root).standardizedFileURL
        }
        return context.mainRoot
            .appendingPathComponent(context.config.pool.root)
            .standardizedFileURL
    }

    func validate(config: TreepoolConfig, in mainRoot: URL) throws {
        guard !config.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TreepoolError.invalidConfig("remote must not be empty")
        }
        guard (1...64).contains(config.pool.size) else {
            throw TreepoolError.invalidConfig("pool.size must be between 1 and 64")
        }
        guard config.pool.pattern.components(separatedBy: "{index}").count == 2 else {
            throw TreepoolError.invalidConfig("pool.pattern must contain exactly one {index}")
        }
        let names = (1...config.pool.size).map {
            config.pool.pattern.replacingOccurrences(of: "{index}", with: String($0))
        }
        guard Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw TreepoolError.invalidConfig(
                "pool.pattern must produce unique single-component slot names"
            )
        }
        _ = try normalizedCopyPatterns(config.copyPatterns)
        try validateHooks(config.hooks.postAssign, name: "postAssign")
        try validateHooks(config.hooks.preRelease, name: "preRelease")
        let context = RepositoryContext(
            mainRoot: mainRoot,
            commonGitDirectory: mainRoot.appendingPathComponent(".git"),
            config: config
        )
        let root = normalizedPath(poolRoot(context).path)
        let main = normalizedPath(mainRoot.path)
        guard root != main, !isDescendant(root, of: main) else {
            throw TreepoolError.invalidConfig("pool.root must be outside the primary checkout")
        }
    }

    func validateHooks(_ commands: [String], name: String) throws {
        for command in commands where command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TreepoolError.invalidConfig("hooks.\(name) entries must not be empty")
        }
    }

    func runHooks(_ commands: [String], name: String, at directory: URL) throws {
        for command in commands {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try ProcessRunner.run(
                "/bin/sh", ["-c", trimmed],
                directory: directory,
                streamOutput: true,
                allowFailure: true
            )
            guard result.status == 0 else {
                let output = [result.stderr, result.stdout]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let suffix = output.isEmpty ? "" : ": \(output)"
                throw TreepoolError.unsafe(
                    "hooks.\(name) command failed (exit \(result.status)): \(trimmed)\(suffix)"
                )
            }
        }
    }

    func normalizedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    func isDescendant(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    func slotName(index: Int, context: RepositoryContext) -> String {
        context.config.pool.pattern.replacingOccurrences(of: "{index}", with: String(index))
    }

    func slotURL(index: Int, context: RepositoryContext) -> URL {
        poolRoot(context).appendingPathComponent(slotName(index: index, context: context))
    }

    func slotName(for url: URL, context: RepositoryContext) -> String? {
        for index in 1...context.config.pool.size {
            if slotURL(index: index, context: context).standardizedFileURL.path
                == url.standardizedFileURL.path {
                return slotName(index: index, context: context)
            }
        }
        return nil
    }

    func resolvedBase(in context: RepositoryContext) throws -> String {
        let base = context.config.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return try resolveRef(
            base.isEmpty ? detectBaseBranch(at: context.mainRoot) : base,
            in: context
        )
    }

    func resolveRef(_ ref: String, in context: RepositoryContext) throws -> String {
        let remote = "\(context.config.remote)/\(ref)"
        if commitExists(ref, context: context) { return ref }
        if refExists("refs/heads/\(ref)", context: context) { return ref }
        if refExists("refs/remotes/\(remote)", context: context) { return remote }
        throw TreepoolError.git("base ref '\(ref)' does not exist")
    }

    func commitExists(_ ref: String, context: RepositoryContext) -> Bool {
        let result = try? ProcessRunner.run(
            "git", ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
            directory: context.mainRoot,
            allowFailure: true
        )
        return result?.status == 0
    }

    func validateBranchName(_ branch: String, _ context: RepositoryContext) throws {
        try validateNewBranchName(branch, context)
        guard !refExists("refs/heads/\(branch)", context: context) else {
            throw TreepoolError.git("branch '\(branch)' already exists; use 'twt start'")
        }
    }

    func validateNewBranchName(_ branch: String, _ context: RepositoryContext) throws {
        let result = try ProcessRunner.run(
            "git", ["check-ref-format", "--branch", branch],
            directory: context.mainRoot,
            allowFailure: true
        )
        guard result.status == 0 else {
            throw TreepoolError.git("invalid branch name '\(branch)'")
        }
    }

    func refExists(_ ref: String, context: RepositoryContext) -> Bool {
        refExists(ref, at: context.mainRoot)
    }

    func refExists(_ ref: String, at root: URL) -> Bool {
        let result = try? ProcessRunner.run(
            "git", ["show-ref", "--verify", "--quiet", ref],
            directory: root,
            allowFailure: true
        )
        return result?.status == 0
    }

    func gitStatusClean(at directory: URL) throws -> Bool {
        try gitOutput(["status", "--porcelain", "--untracked-files=normal"], at: directory).isEmpty
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) throws -> CommandResult {
        try ProcessRunner.run("git", arguments, directory: directory)
    }

    func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        try git(arguments, at: directory).stdout
    }
}
