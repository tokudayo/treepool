import Foundation

public struct TreepoolConfig: Codable, Sendable {
    public struct Pool: Codable, Sendable {
        public var size: Int
        public var root: String
        public var pattern: String

        public init(size: Int = 4, root: String, pattern: String = "tree-{index}") {
            self.size = size
            self.root = root
            self.pattern = pattern
        }
    }

    public var schemaVersion: Int
    public var baseBranch: String
    public var remote: String
    public var pool: Pool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseBranch, remote, pool
    }

    public init(
        schemaVersion: Int = 1,
        baseBranch: String = "",
        remote: String = "origin",
        pool: Pool
    ) {
        self.schemaVersion = schemaVersion
        self.baseBranch = baseBranch
        self.remote = remote
        self.pool = pool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch) ?? ""
        remote = try container.decode(String.self, forKey: .remote)
        pool = try container.decode(Pool.self, forKey: .pool)
    }
}

public struct WorktreeInfo: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let branch: String?
    public let head: String
    public let detached: Bool
    public let clean: Bool
    public let lastUsed: Date?
    public let isPoolSlot: Bool
    public let exists: Bool
}

public struct PoolReconcileResult: Codable, Sendable {
    public let dryRun: Bool
    public let created: [String]
    public let retained: [String]
    public let repaired: [String]
    public let extras: [String]
    public let warnings: [String]

    public init(
        dryRun: Bool,
        created: [String],
        retained: [String],
        repaired: [String],
        extras: [String],
        warnings: [String]
    ) {
        self.dryRun = dryRun
        self.created = created
        self.retained = retained
        self.repaired = repaired
        self.extras = extras
        self.warnings = warnings
    }
}

struct RuntimeState: Codable {
    var schemaVersion = 1
    var slots: [String: SlotState] = [:]
}

struct SlotState: Codable {
    var lastUsed: Date?
}

public struct RepositoryContext: Sendable {
    public let mainRoot: URL
    public let commonGitDirectory: URL
    public let config: TreepoolConfig

    public var stateDirectory: URL {
        commonGitDirectory.appendingPathComponent("twt", isDirectory: true)
    }
}

public enum TreepoolError: Error, CustomStringConvertible, Sendable {
    case notRepository
    case missingConfig(String)
    case invalidConfig(String)
    case alreadyConfigured(String)
    case noAvailableSlot
    case noMatch(String)
    case ambiguous(String, [String])
    case unsafe(String)
    case git(String)
    case locked

    public var description: String {
        switch self {
        case .notRepository: return "Not inside a Git repository."
        case .missingConfig(let path): return "No .twt.json found at \(path). Run 'twt init' first."
        case .invalidConfig(let message): return "Invalid configuration: \(message)"
        case .alreadyConfigured(let path): return "Treepool is already configured at \(path). Run 'twt setup' after editing the existing policy."
        case .noAvailableSlot: return "No clean, detached pool slot is available."
        case .noMatch(let query): return "No worktree matches '\(query)'."
        case .ambiguous(let query, let matches): return "Ambiguous match for '\(query)': \(matches.joined(separator: ", "))."
        case .unsafe(let message): return message
        case .git(let message): return "Git failed: \(message)"
        case .locked: return "Another Treepool operation is already running for this repository."
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .notRepository, .missingConfig, .invalidConfig, .alreadyConfigured: return 3
        case .noAvailableSlot, .noMatch, .ambiguous: return 4
        case .unsafe: return 5
        case .git: return 6
        case .locked: return 8
        }
    }

    public var code: String {
        switch self {
        case .notRepository: return "not_repository"
        case .missingConfig: return "missing_config"
        case .invalidConfig: return "invalid_config"
        case .alreadyConfigured: return "already_configured"
        case .noAvailableSlot: return "no_available_slot"
        case .noMatch: return "no_match"
        case .ambiguous: return "ambiguous_match"
        case .unsafe: return "unsafe"
        case .git: return "git_failure"
        case .locked: return "locked"
        }
    }

    public var suggestion: String? {
        switch self {
        case .notRepository:
            return "Run this command inside a Git worktree."
        case .noAvailableSlot:
            return "Run 'twt list' to inspect active, dirty, or missing slots."
        case .noMatch, .ambiguous:
            return "Run 'twt list' and retry with an exact slot, branch, or path."
        case .unsafe(let message) where message.contains("uncommitted changes"):
            return "Commit or resolve the changes in that worktree, then retry."
        case .unsafe(let message) where message.contains("Stale pool registrations"):
            return "Preview recovery with 'twt repair --dry-run'."
        case .git(let message) where message.contains("does not exist"):
            return "Treepool does not fetch; run 'git fetch' if the ref exists remotely."
        case .locked:
            return "Wait for the other Treepool operation to finish, then retry."
        default:
            return nil
        }
    }
}
