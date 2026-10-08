import Foundation

struct GitMetadata {
    let mainRoot: URL
    let commonGitDirectory: URL
}

struct RawWorktree {
    var path = ""
    var head = ""
    var branch: String?
    var detached = false
}

extension TreepoolManager {
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

    func gitMetadata(at directory: URL) throws -> GitMetadata {
        let inside = try ProcessRunner.run(
            "git", ["rev-parse", "--is-inside-work-tree"],
            directory: directory,
            allowFailure: true
        )
        guard inside.status == 0, inside.stdout == "true" else {
            throw TreepoolError.notRepository
        }
        let common = try gitOutput(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            at: directory
        )
        let porcelain = try gitOutput(["worktree", "list", "--porcelain"], at: directory)
        guard let first = porcelain.split(separator: "\n").first,
              first.hasPrefix("worktree ") else {
            throw TreepoolError.notRepository
        }
        return GitMetadata(
            mainRoot: URL(
                fileURLWithPath: String(first.dropFirst("worktree ".count))
            ).standardizedFileURL,
            commonGitDirectory: URL(fileURLWithPath: common).standardizedFileURL
        )
    }

    func detectBaseBranch(at root: URL) -> String {
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

    func rawWorktrees(in context: RepositoryContext) throws -> [RawWorktree] {
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

    func makeInfo(
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
        return WorktreeInfo(
            name: name,
            path: raw.path,
            branch: raw.branch,
            head: raw.head,
            detached: raw.detached,
            clean: exists ? try gitStatusClean(at: url) : false,
            lastUsed: state.slots[name]?.lastUsed,
            isPoolSlot: slotName(for: url, context: context) != nil,
            exists: exists
        )
    }

    func info(
        forPath path: String,
        context: RepositoryContext,
        state: RuntimeState
    ) throws -> WorktreeInfo {
        let expected = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let raw = try rawWorktrees(in: context).first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == expected
        }) else {
            throw TreepoolError.noMatch(path)
        }
        return try makeInfo(raw: raw, context: context, state: state)
    }

    func selectIdleSlot(
        _ context: RepositoryContext,
        _ state: RuntimeState,
        requestedSlot: String? = nil,
        fingerprintRef: String? = nil
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
                throw TreepoolError.unsafe("Requested slot \(slot.name) is not clean and detached.")
            }
            return slot
        }
        let idleSlots = slots.filter { $0.detached && $0.clean }
        guard !idleSlots.isEmpty else {
            throw TreepoolError.noAvailableSlot
        }
        if let fingerprint = try normalizedFingerprint(context.config.fingerprint),
           let fingerprintRef,
           let slot = try selectFingerprintSlot(
               from: idleSlots,
               targetRef: fingerprintRef,
               fingerprint: fingerprint,
               context: context
           ) {
            return slot
        }
        guard let slot = idleSlots.min(by: {
            ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast)
        }) else {
            throw TreepoolError.noAvailableSlot
        }
        return slot
    }

    private func selectFingerprintSlot(
        from slots: [WorktreeInfo],
        targetRef: String,
        fingerprint: String,
        context: RepositoryContext
    ) throws -> WorktreeInfo? {
        guard let targetHash = fingerprintHash(
            ref: targetRef, path: fingerprint, context: context
        ) else { return nil }

        let ranked = slots.map { slot in
            let hash = fingerprintHash(ref: slot.head, path: fingerprint, context: context)
            return (
                slot: slot,
                exact: hash == targetHash,
                changes: hash == targetHash
                    ? 0
                    : fingerprintChangeCount(
                        from: slot.head,
                        to: targetRef,
                        path: fingerprint,
                        context: context
                    )
            )
        }
        return ranked.min {
            if $0.exact != $1.exact { return $0.exact && !$1.exact }
            if $0.changes != $1.changes { return $0.changes < $1.changes }
            return ($0.slot.lastUsed ?? .distantPast) < ($1.slot.lastUsed ?? .distantPast)
        }?.slot
    }

    private func fingerprintHash(
        ref: String,
        path: String,
        context: RepositoryContext
    ) -> String? {
        let result = try? ProcessRunner.run(
            "git", ["rev-parse", "--verify", "--quiet", "\(ref):\(path)"],
            directory: context.mainRoot,
            allowFailure: true
        )
        guard let result, result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    private func fingerprintChangeCount(
        from sourceRef: String,
        to targetRef: String,
        path: String,
        context: RepositoryContext
    ) -> Int {
        let result = try? ProcessRunner.run(
            "git", ["diff", "--numstat", sourceRef, targetRef, "--", path],
            directory: context.mainRoot,
            allowFailure: true
        )
        guard let result, result.status == 0, !result.stdout.isEmpty else { return .max }
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
              let additions = Int(fields[0]),
              let deletions = Int(fields[1]) else { return .max }
        let (changes, overflow) = additions.addingReportingOverflow(deletions)
        return overflow ? .max : changes
    }

    func resolve(_ query: String, from items: [WorktreeInfo]) throws -> WorktreeInfo {
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
}
