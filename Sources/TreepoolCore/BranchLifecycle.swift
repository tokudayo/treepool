import Foundation

extension TreepoolManager {
    public func createBranch(
        _ branch: String,
        from: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> WorktreeInfo {
        try createBranchWithWarnings(branch, from: from, in: context, slot: requestedSlot).slot
    }

    public func createBranchWithWarnings(
        _ branch: String,
        from: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> SlotAssignmentResult {
        let lock = try acquireLock(context)
        defer { _ = lock }
        try validateBranchName(branch, context)
        let slot = try assignIdleSlot(in: context, requestedSlot: requestedSlot) { slotURL in
            try git(["switch", "-c", branch, resolveRef(from, in: context)], at: slotURL)
        }
        return SlotAssignmentResult(slot: slot.info, warnings: slot.warnings)
    }

    public func switchBranch(
        _ branch: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> WorktreeInfo {
        try switchBranchWithWarnings(branch, in: context, slot: requestedSlot).slot
    }

    public func switchBranchWithWarnings(
        _ branch: String,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> SlotAssignmentResult {
        let lock = try acquireLock(context)
        defer { _ = lock }
        let slot = try assignIdleSlot(in: context, requestedSlot: requestedSlot) { slotURL in
            try switchExistingBranch(branch, in: context, at: slotURL)
        }
        return SlotAssignmentResult(slot: slot.info, warnings: slot.warnings)
    }

    /// Resumes an assigned pool branch, switches an existing branch into an idle slot,
    /// or creates a new branch when no matching local or configured-remote branch exists.
    public func startBranch(
        _ branch: String,
        from requestedBase: String? = nil,
        in context: RepositoryContext,
        slot requestedSlot: String? = nil
    ) throws -> SlotStartResult {
        let lock = try acquireLock(context)
        defer { _ = lock }

        var state = try loadState(context)
        let poolSlots = try list(in: context).filter(\.isPoolSlot)
        if let active = poolSlots.first(where: {
            $0.branch == branch && $0.exists && !$0.detached
        }) {
            if let requestedSlot {
                let requested = try resolve(requestedSlot, from: poolSlots)
                guard requested.path == active.path else {
                    throw TreepoolError.unsafe(
                        "Branch '\(branch)' is already active in \(active.name), not \(requested.name)."
                    )
                }
            }
            state.slots[active.name, default: SlotState()].lastUsed = Date()
            try saveState(state, context)
            return SlotStartResult(
                action: .resumed,
                slot: try info(forPath: active.path, context: context, state: state),
                warnings: []
            )
        }

        var action = SlotStartAction.switched
        let assigned = try assignIdleSlot(
            in: context,
            state: state,
            requestedSlot: requestedSlot
        ) { slotURL in
            if branchExists(branch, context: context) {
                try switchExistingBranch(branch, in: context, at: slotURL)
            } else {
                try validateNewBranchName(branch, context)
                let base = try startBase(requestedBase, context: context)
                try git(["switch", "-c", branch, resolveRef(base, in: context)], at: slotURL)
                action = .created
            }
        }
        return SlotStartResult(action: action, slot: assigned.info, warnings: assigned.warnings)
    }

    public func release(_ query: String, in context: RepositoryContext) throws -> WorktreeInfo {
        let lock = try acquireLock(context)
        defer { _ = lock }
        let slot = try resolve(query, from: try list(in: context).filter(\.isPoolSlot))
        guard !slot.detached else {
            throw TreepoolError.unsafe("\(slot.name) is already idle.")
        }
        let slotURL = URL(fileURLWithPath: slot.path)
        try runHooks(context.config.hooks.preRelease, name: "preRelease", at: slotURL)
        let afterHooks = try info(forPath: slot.path, context: context, state: loadState(context))
        guard afterHooks.clean else {
            throw TreepoolError.unsafe(
                "Refusing to release \(slot.name): the worktree has uncommitted changes."
            )
        }
        try git(["switch", "--detach"], at: slotURL)
        var state = try loadState(context)
        state.slots[slot.name, default: SlotState()].lastUsed = Date()
        try saveState(state, context)
        return try info(forPath: slot.path, context: context, state: state)
    }

    /// Releases the managed pool slot containing `directory`.
    public func releaseCurrent(at directory: URL, in context: RepositoryContext) throws -> WorktreeInfo {
        let metadata = try gitMetadata(at: directory)
        guard metadata.mainRoot == context.mainRoot else { throw TreepoolError.notRepository }
        let root = URL(fileURLWithPath: try gitOutput(
            ["rev-parse", "--show-toplevel"],
            at: directory
        )).standardizedFileURL
        let current = try info(forPath: root.path, context: context, state: loadState(context))
        guard current.isPoolSlot else {
            throw TreepoolError.unsafe(
                "The current directory is not a managed pool slot. Pass a branch, slot, or path to release a slot."
            )
        }
        return try release(current.path, in: context)
    }
}

private struct AssignedSlot {
    let info: WorktreeInfo
    let warnings: [String]
}

extension TreepoolManager {
    private func assignIdleSlot(
        in context: RepositoryContext,
        state initialState: RuntimeState? = nil,
        requestedSlot: String?,
        checkout: (URL) throws -> Void
    ) throws -> AssignedSlot {
        var state = try initialState ?? loadState(context)
        let slot = try selectIdleSlot(context, state, requestedSlot: requestedSlot)
        let slotURL = URL(fileURLWithPath: slot.path)
        try checkout(slotURL)
        let warnings = try copyConfiguredFiles(
            from: context.mainRoot,
            to: slotURL,
            patterns: context.config.copyPatterns
        )
        state.slots[slot.name, default: SlotState()].lastUsed = Date()
        try saveState(state, context)
        try runHooks(context.config.hooks.postAssign, name: "postAssign", at: slotURL)
        return AssignedSlot(
            info: try info(forPath: slot.path, context: context, state: state),
            warnings: warnings
        )
    }

    private func switchExistingBranch(
        _ branch: String,
        in context: RepositoryContext,
        at slotURL: URL
    ) throws {
        if refExists("refs/heads/\(branch)", context: context) {
            try git(["switch", branch], at: slotURL)
        } else if refExists("refs/remotes/\(context.config.remote)/\(branch)", context: context) {
            try git(
                ["switch", "--track", "-c", branch, "\(context.config.remote)/\(branch)"],
                at: slotURL
            )
        } else {
            throw TreepoolError.git(
                "branch '\(branch)' does not exist locally or on \(context.config.remote)"
            )
        }
    }

    private func branchExists(_ branch: String, context: RepositoryContext) -> Bool {
        refExists("refs/heads/\(branch)", context: context)
            || refExists("refs/remotes/\(context.config.remote)/\(branch)", context: context)
    }

    private func startBase(_ requestedBase: String?, context: RepositoryContext) throws -> String {
        let requested = requestedBase?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty { return requested }
        let configured = context.config.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else {
            throw TreepoolError.invalidConfig("baseBranch is empty; pass '--from REF' to 'twt start'")
        }
        return configured
    }
}
