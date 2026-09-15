import Foundation

extension TreepoolManager {
    @discardableResult
    public func initialize(at directory: URL, slotCount: Int = 4) throws -> RepositoryContext {
        guard (1...64).contains(slotCount) else {
            throw TreepoolError.invalidConfig("pool size must be between 1 and 64")
        }
        let git = try gitMetadata(at: directory)
        let repositoryName = git.mainRoot.lastPathComponent
        let config = TreepoolConfig(pool: .init(
            size: slotCount,
            root: "../\(repositoryName).worktrees"
        ))
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
            let data = try Data(contentsOf: configURL)
            let config = try makeDecoder().decode(TreepoolConfig.self, from: data)
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

    func reconcilePool(
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
                if exists { retained.append(path) } else { stale.append(path) }
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

    func addDetachedWorktree(
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
}
