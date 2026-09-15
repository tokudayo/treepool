#if os(macOS)
import Foundation
import TreepoolCore

struct RepositorySnapshot: Identifiable, Sendable {
    let id: String
    let context: RepositoryContext
    let worktrees: [WorktreeInfo]
}

struct RepositoryFailure: Identifiable, Sendable {
    let path: String
    let message: String
    var id: String { path }
}

struct OpenApplication: Identifiable, Hashable {
    let url: URL

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}
#endif
