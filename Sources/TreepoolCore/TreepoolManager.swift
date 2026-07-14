import Foundation

public final class TreepoolManager: Sendable {
    private var fileManager: FileManager { .default }

    public init() {}

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public func initialize(at directory: URL, slotCount: Int = 4) throws -> RepositoryContext {
        guard (1...64).contains(slotCount) else {
            throw TreepoolError.invalidConfig("pool size must be between 1 and 64")
        }
        let git = try gitMetadata(at: directory)
        let repositoryName = git.mainRoot.lastPathComponent
        let root = "../\(repositoryName).worktrees"
        let config = TreepoolConfig(
            pool: .init(size: slotCount, root: root)
        )
        let configURL = git.mainRoot.appendingPathComponent(".twt.json")
        guard !fileManager.fileExists(atPath: configURL.path) else {
            throw TreepoolError.alreadyConfigured(configURL.path)
        }
        let context = RepositoryContext(
            mainRoot: git.mainRoot,
            commonGitDirectory: git.commonGitDirectory,
            config: config
        )
        try validate(config: config, in: git.mainRoot)
        let lock = try acquireLock(context)
        defer { _ = lock }
        _ = try reconcilePool(in: context, dryRun: false, repairStale: false)
        try makeEncoder().encode(config).write(to: configURL, options: .atomic)
        return context
    }

    public func context(at directory: URL) throws -> RepositoryContext {
        let git = try gitMetadata(at: directory)
        let configURL = git.mainRoot.appendingPathComponent(".twt.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw TreepoolError.missingConfig(configURL.path)
        }
        do {
            let config = try makeDecoder().decode(TreepoolConfig.self, from: Data(contentsOf: configURL))
            guard config.schemaVersion == 1 else {
                throw TreepoolError.invalidConfig("unsupported schemaVersion \(config.schemaVersion)")
            }
            try validate(config: config, in: git.mainRoot)
            return RepositoryContext(
                mainRoot: git.mainRoot,
                commonGitDirectory: git.commonGitDirectory,
                config: config
            )
        } catch let error as TreepoolError {
            throw error
        } catch {
            throw TreepoolError.invalidConfig(error.localizedDescription)
        }
    }

    public func setup(in context: RepositoryContext, dryRun: Bool = false) throws -> PoolReconcileResult {
        let lock = try acquireLock(context)
        defer { _ = lock }
        return try reconcilePool(in: context, dryRun: dryRun, repairStale: false)
    }

    public func repair(in context: RepositoryContext, dryRun: Bool = false) throws -> PoolReconcileResult {
        let lock = try acquireLock(context)
        defer { _ = lock }
        return try reconcilePool(in: context, dryRun: dryRun, repairStale: true)
    }

    private func reconcilePool(
        in context: RepositoryContext,
        dryRun: Bool,
        repairStale: Bool
    ) throws -> PoolReconcileResult {
        try validate(config: context.config, in: context.mainRoot)
        let registered = try rawWorktrees(in: context)
        let byPath = Dictionary(uniqueKeysWithValues: registered.map { (normalizedPath($0.path), $0) })
        let desired = (1...context.config.pool.size).map { slotURL(index: $0, context: context) }
        let desiredPaths = Set(desired.map { normalizedPath($0.path) })
        var retained: [String] = []
        var missing: [String] = []
        var stale: [String] = []
        var conflicts: [String] = []

        for slot in desired {
            let path = normalizedPath(slot.path)
            let exists = fileManager.fileExists(atPath: path)
            if byPath[path] != nil {
                if exists { retained.append(path) }
                else { stale.append(path) }
            } else if exists {
                conflicts.append(path)
            } else {
                missing.append(path)
            }
        }

        guard conflicts.isEmpty else {
            throw TreepoolError.unsafe(
                "Refusing to set up the pool because these desired paths already exist but are not registered worktrees: \(conflicts.joined(separator: ", "))."
            )
        }
        guard stale.isEmpty || repairStale else {
            throw TreepoolError.unsafe(
                "Stale pool registrations require 'twt repair': \(stale.joined(separator: ", "))."
            )
        }

        let root = normalizedPath(poolRoot(context).path)
        let main = normalizedPath(context.mainRoot.path)
        let extras = registered.map(\.path).map(normalizedPath).filter {
            $0 != main && isDescendant($0, of: root) && !desiredPaths.contains($0)
        }.sorted()
        let plannedCreates = missing + stale
        if !dryRun, !plannedCreates.isEmpty {
            let base = try resolvedBase(in: context)
            var completed: [String] = []
            do {
                for path in stale {
                    let registeredPath = byPath[path]?.path ?? path
                    try git(["worktree", "remove", "--force", registeredPath], at: context.mainRoot)
                    try addDetachedWorktree(at: path, base: base, context: context, force: true)
                    completed.append(path)
                }
                for path in missing {
                    try addDetachedWorktree(at: path, base: base, context: context)
                    completed.append(path)
                }
            } catch {
                throw TreepoolError.git(
                    "pool reconciliation stopped after creating \(completed.count) of \(plannedCreates.count) slots; rerun the same command after resolving the error: \(error)"
                )
            }
        }

        let warnings = extras.isEmpty ? [] : [
            "Extra registered worktrees were left untouched: \(extras.joined(separator: ", "))"
        ]
        return PoolReconcileResult(
            dryRun: dryRun,
            created: missing.sorted(),
            retained: retained.sorted(),
            repaired: stale.sorted(),
            extras: extras,
            warnings: warnings
        )
    }

    private func addDetachedWorktree(
        at path: String,
        base: String,
        context: RepositoryContext,
        force: Bool = false
    ) throws {
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var arguments = ["worktree", "add"]
        if force { arguments.append("--force") }
        arguments += ["--detach", path, base]
        try git(arguments, at: context.mainRoot)
    }

    public func createBranch(
        _ branch: String,
        from: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> WorktreeInfo {
        let lock = try acquireLock(context)
        defer { _ = lock }
        try validateBranchName(branch, context)
        var state = try loadState(context)
        let slot = try selectIdleSlot(context, state, requestedSlot: requestedSlot)
        let baseRef = try resolveRef(from, in: context)
        try git(["switch", "-c", branch, baseRef], at: URL(fileURLWithPath: slot.path))
        state.slots[slot.name, default: SlotState()].lastUsed = Date()
        try saveState(state, context)
        return try info(forPath: slot.path, context: context, state: state)
    }

    public func switchBranch(
        _ branch: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> WorktreeInfo {
        let lock = try acquireLock(context)
        defer { _ = lock }
        var state = try loadState(context)
        let slot = try selectIdleSlot(context, state, requestedSlot: requestedSlot)
        let slotURL = URL(fileURLWithPath: slot.path)

        if refExists("refs/heads/\(branch)", context: context) {
            try git(["switch", branch], at: slotURL)
        } else if refExists("refs/remotes/\(context.config.remote)/\(branch)", context: context) {
            try git(
                ["switch", "--track", "-c", branch, "\(context.config.remote)/\(branch)"],
                at: slotURL
            )
        } else {
            throw TreepoolError.git("branch '\(branch)' does not exist locally or on \(context.config.remote)")
        }
        state.slots[slot.name, default: SlotState()].lastUsed = Date()
        try saveState(state, context)
        return try info(forPath: slot.path, context: context, state: state)
    }

    public func release(_ query: String, in context: RepositoryContext) throws -> WorktreeInfo {
        let lock = try acquireLock(context)
        defer { _ = lock }
        let slot = try resolve(query, from: try list(in: context).filter(\.isPoolSlot))
        guard slot.clean else {
            throw TreepoolError.unsafe("Refusing to release \(slot.name): the worktree has uncommitted changes.")
        }
        guard !slot.detached else {
            throw TreepoolError.unsafe("\(slot.name) is already idle.")
        }
        try git(["switch", "--detach"], at: URL(fileURLWithPath: slot.path))
        var state = try loadState(context)
        state.slots[slot.name, default: SlotState()].lastUsed = Date()
        try saveState(state, context)
        return try info(forPath: slot.path, context: context, state: state)
    }

    /// Releases the managed pool slot containing `directory`.
    ///
    /// The directory may be anywhere below the worktree root. The primary checkout and
    /// unmanaged worktrees deliberately require an explicit release query instead.
    public func releaseCurrent(at directory: URL, in context: RepositoryContext) throws -> WorktreeInfo {
        let metadata = try gitMetadata(at: directory)
        guard metadata.mainRoot == context.mainRoot else { throw TreepoolError.notRepository }

        let root = URL(fileURLWithPath: try gitOutput(
            ["rev-parse", "--show-toplevel"],
            at: directory
        )).standardizedFileURL
        let state = try loadState(context)
        let current = try info(forPath: root.path, context: context, state: state)
        guard current.isPoolSlot else {
            throw TreepoolError.unsafe(
                "The current directory is not a managed pool slot. Pass a branch, slot, or path to release a slot."
            )
        }
        return try release(current.path, in: context)
    }

    public func list(in context: RepositoryContext) throws -> [WorktreeInfo] {
        let state = try loadState(context)
        return try rawWorktrees(in: context).map { raw in
            try makeInfo(raw: raw, context: context, state: state)
        }.sorted {
            if $0.path == context.mainRoot.path { return true }
            if $1.path == context.mainRoot.path { return false }
            return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
        }
    }

    private struct GitMetadata {
        let mainRoot: URL
        let commonGitDirectory: URL
    }

    private struct RawWorktree {
        var path = ""
        var head = ""
        var branch: String?
        var detached = false
    }

    private func gitMetadata(at directory: URL) throws -> GitMetadata {
        let inside = try ProcessRunner.run(
            "git", ["rev-parse", "--is-inside-work-tree"],
            directory: directory,
            allowFailure: true
        )
        guard inside.status == 0, inside.stdout == "true" else { throw TreepoolError.notRepository }
        let common = try gitOutput(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            at: directory
        )
        let porcelain = try gitOutput(["worktree", "list", "--porcelain"], at: directory)
        guard let first = porcelain.split(separator: "\n").first,
              first.hasPrefix("worktree ") else { throw TreepoolError.notRepository }
        let mainPath = String(first.dropFirst("worktree ".count))
        return GitMetadata(
            mainRoot: URL(fileURLWithPath: mainPath).standardizedFileURL,
            commonGitDirectory: URL(fileURLWithPath: common).standardizedFileURL
        )
    }

    private func detectBaseBranch(at root: URL) -> String {
        let symbolic = try? gitOutput(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            at: root
        )
        if let symbolic {
            let prefix = "origin/"
            return symbolic.hasPrefix(prefix) ? String(symbolic.dropFirst(prefix.count)) : symbolic
        }
        if refExists("refs/heads/main", at: root) { return "main" }
        if refExists("refs/heads/master", at: root) { return "master" }
        return (try? gitOutput(["branch", "--show-current"], at: root)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "main"
    }

    private func rawWorktrees(in context: RepositoryContext) throws -> [RawWorktree] {
        let output = try gitOutput(["worktree", "list", "--porcelain"], at: context.mainRoot)
        var result: [RawWorktree] = []
        var current: RawWorktree?
        for line in output.components(separatedBy: .newlines) + [""] {
            if line.isEmpty {
                if let current { result.append(current) }
                current = nil
            } else if line.hasPrefix("worktree ") {
                current = RawWorktree(path: String(line.dropFirst(9)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch refs/heads/") {
                current?.branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "detached" {
                current?.detached = true
            }
        }
        return result
    }

    private func makeInfo(
        raw: RawWorktree,
        context: RepositoryContext,
        state: RuntimeState
    ) throws -> WorktreeInfo {
        let url = URL(fileURLWithPath: raw.path)
        let name = slotName(for: url, context: context) ?? (
            url.standardizedFileURL.path == context.mainRoot.standardizedFileURL.path
                ? context.mainRoot.lastPathComponent
                : url.lastPathComponent
        )
        let exists = fileManager.fileExists(atPath: raw.path)
        let clean = exists ? try gitStatusClean(at: url) : false
        let slotState = state.slots[name]
        return WorktreeInfo(
            name: name,
            path: raw.path,
            branch: raw.branch,
            head: raw.head,
            detached: raw.detached,
            clean: clean,
            lastUsed: slotState?.lastUsed,
            isPoolSlot: slotName(for: url, context: context) != nil,
            exists: exists
        )
    }

    private func info(
        forPath path: String,
        context: RepositoryContext,
        state: RuntimeState
    ) throws -> WorktreeInfo {
        guard let raw = try rawWorktrees(in: context).first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }) else { throw TreepoolError.noMatch(path) }
        return try makeInfo(raw: raw, context: context, state: state)
    }

    private func selectIdleSlot(
        _ context: RepositoryContext,
        _ state: RuntimeState,
        requestedSlot: String? = nil
    ) throws -> WorktreeInfo {
        let slots = try rawWorktrees(in: context).compactMap { raw -> WorktreeInfo? in
            guard slotName(for: URL(fileURLWithPath: raw.path), context: context) != nil else {
                return nil
            }
            return try makeInfo(raw: raw, context: context, state: state)
        }
        if let requestedSlot {
            let slot = try resolve(requestedSlot, from: slots)
            guard slot.exists, slot.detached, slot.clean else {
                throw TreepoolError.unsafe(
                    "Requested slot \(slot.name) is not clean and detached."
                )
            }
            return slot
        }
        let idleSlots = slots.filter { $0.detached && $0.clean }
        guard let slot = idleSlots.min(by: {
            ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast)
        }) else { throw TreepoolError.noAvailableSlot }
        return slot
    }

    private func resolve(_ query: String, from items: [WorktreeInfo]) throws -> WorktreeInfo {
        let lowered = query.lowercased()
        let exact = items.filter {
            $0.name.lowercased() == lowered
                || $0.branch?.lowercased() == lowered
                || $0.path.lowercased() == lowered
        }
        if exact.count == 1 { return exact[0] }
        let matches = items.filter {
            $0.name.lowercased().contains(lowered)
                || ($0.branch?.lowercased().contains(lowered) ?? false)
                || $0.path.lowercased().contains(lowered)
        }
        guard !matches.isEmpty else { throw TreepoolError.noMatch(query) }
        guard matches.count == 1 else {
            throw TreepoolError.ambiguous(query, matches.map {
                "\($0.name) (\($0.branch ?? "detached"))"
            })
        }
        return matches[0]
    }

    private func loadState(_ context: RepositoryContext) throws -> RuntimeState {
        let url = context.stateDirectory.appendingPathComponent("state.json")
        guard fileManager.fileExists(atPath: url.path) else { return RuntimeState() }
        do {
            return try makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: url))
        } catch {
            throw TreepoolError.invalidConfig("runtime state: \(error.localizedDescription)")
        }
    }

    private func saveState(_ state: RuntimeState, _ context: RepositoryContext) throws {
        try fileManager.createDirectory(at: context.stateDirectory, withIntermediateDirectories: true)
        try makeEncoder().encode(state).write(
            to: context.stateDirectory.appendingPathComponent("state.json"),
            options: .atomic
        )
    }

    private func acquireLock(_ context: RepositoryContext) throws -> RepositoryLock {
        try RepositoryLock(url: context.stateDirectory.appendingPathComponent("operation.lock"))
    }

    private func poolRoot(_ context: RepositoryContext) -> URL {
        if context.config.pool.root.hasPrefix("/") {
            return URL(fileURLWithPath: context.config.pool.root).standardizedFileURL
        }
        return context.mainRoot
            .appendingPathComponent(context.config.pool.root)
            .standardizedFileURL
    }

    private func validate(config: TreepoolConfig, in mainRoot: URL) throws {
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
            throw TreepoolError.invalidConfig("pool.pattern must produce unique single-component slot names")
        }
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

    private func normalizedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    private func isDescendant(_ path: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    private func slotName(index: Int, context: RepositoryContext) -> String {
        context.config.pool.pattern.replacingOccurrences(of: "{index}", with: String(index))
    }

    private func slotURL(index: Int, context: RepositoryContext) -> URL {
        poolRoot(context).appendingPathComponent(slotName(index: index, context: context))
    }

    private func slotName(for url: URL, context: RepositoryContext) -> String? {
        for index in 1...context.config.pool.size {
            if slotURL(index: index, context: context).standardizedFileURL.path
                == url.standardizedFileURL.path {
                return slotName(index: index, context: context)
            }
        }
        return nil
    }

    private func resolvedBase(in context: RepositoryContext) throws -> String {
        let base = context.config.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return try resolveRef(
            base.isEmpty ? detectBaseBranch(at: context.mainRoot) : base,
            in: context
        )
    }

    private func resolveRef(_ ref: String, in context: RepositoryContext) throws -> String {
        let remote = "\(context.config.remote)/\(ref)"
        if commitExists(ref, context: context) { return ref }
        if refExists("refs/heads/\(ref)", context: context) { return ref }
        if refExists("refs/remotes/\(remote)", context: context) { return remote }
        throw TreepoolError.git("base ref '\(ref)' does not exist")
    }

    private func commitExists(_ ref: String, context: RepositoryContext) -> Bool {
        let result = try? ProcessRunner.run(
            "git", ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
            directory: context.mainRoot,
            allowFailure: true
        )
        return result?.status == 0
    }

    private func validateBranchName(_ branch: String, _ context: RepositoryContext) throws {
        let result = try ProcessRunner.run(
            "git", ["check-ref-format", "--branch", branch],
            directory: context.mainRoot,
            allowFailure: true
        )
        guard result.status == 0 else { throw TreepoolError.git("invalid branch name '\(branch)'") }
        guard !refExists("refs/heads/\(branch)", context: context) else {
            throw TreepoolError.git("branch '\(branch)' already exists; use 'twt switch'")
        }
    }

    private func refExists(_ ref: String, context: RepositoryContext) -> Bool {
        refExists(ref, at: context.mainRoot)
    }

    private func refExists(_ ref: String, at root: URL) -> Bool {
        let result = try? ProcessRunner.run(
            "git", ["show-ref", "--verify", "--quiet", ref],
            directory: root,
            allowFailure: true
        )
        return result?.status == 0
    }

    private func gitStatusClean(at directory: URL) throws -> Bool {
        try gitOutput(["status", "--porcelain", "--untracked-files=normal"], at: directory).isEmpty
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL) throws -> CommandResult {
        try ProcessRunner.run("git", arguments, directory: directory)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        try git(arguments, at: directory).stdout
    }

}
