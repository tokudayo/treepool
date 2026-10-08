import Foundation
import Testing
@testable import TreepoolCore

@Suite("Treepool core integration")
struct TreepoolCoreTests {
    @Test
    func testInitializationCreatesPool() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        #expect(context.config.baseBranch == "")
        #expect(context.config.pool.size == 2)
        let pool = try fixture.manager.list(in: context).filter(\.isPoolSlot)
        #expect(pool.count == 2)
        #expect(pool.allSatisfy { $0.detached })
        #expect(pool.allSatisfy { $0.clean })
    }

    @Test
    func testBranchLifecyclePreservesBranch() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/one", from: "main", in: context)
        #expect(active.branch == "feature/one")
        #expect(!active.detached)
        #expect(try fixture.manager.release("feature/one", in: context).detached)
        #expect(try fixture.run(
            "git", ["show-ref", "--verify", "refs/heads/feature/one"], at: fixture.repository
        ).status == 0)
    }

    @Test
    func startCreatesResumesAndSwitchesWithoutCallerBranchLookup() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)

        let created = try fixture.manager.startBranch(
            "feature/start", from: "main", in: context
        )
        #expect(created.action == .created)
        #expect(created.slot.branch == "feature/start")

        let resumed = try fixture.manager.startBranch("feature/start", in: context)
        #expect(resumed.action == .resumed)
        #expect(resumed.slot.path == created.slot.path)

        _ = try fixture.manager.release("feature/start", in: context)
        let switched = try fixture.manager.startBranch("feature/start", in: context)
        #expect(switched.action == .switched)
        #expect(switched.slot.path == created.slot.path)
    }

    @Test
    func startUsesConfiguredBaseOnlyWhenCreating() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees")
        ))
        let context = try fixture.manager.context(at: fixture.repository)

        let result = try fixture.manager.startBranch("feature/configured-start", in: context)
        #expect(result.action == .created)
        #expect(result.slot.branch == "feature/configured-start")
    }

    @Test
    func startTracksExistingConfiguredRemoteBranch() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.run("git", ["branch", "feature/remote-start"], at: fixture.repository)
        try fixture.run("git", ["remote", "add", "origin", fixture.repository.path], at: fixture.repository)
        try fixture.run("git", ["fetch", "origin"], at: fixture.repository)
        try fixture.run("git", ["branch", "-D", "feature/remote-start"], at: fixture.repository)

        let result = try fixture.manager.startBranch("feature/remote-start", in: context)
        #expect(result.action == .switched)
        #expect(result.slot.branch == "feature/remote-start")
    }

    @Test
    func startHonorsExplicitSlotWhenResuming() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        _ = try fixture.manager.startBranch(
            "feature/resume-slot", from: "main", in: context, slot: "tree-2"
        )

        let resumed = try fixture.manager.startBranch(
            "feature/resume-slot", in: context, slot: "tree-2"
        )
        #expect(resumed.action == .resumed)
        #expect(resumed.slot.name == "tree-2")
        #expect(throws: TreepoolError.self) {
            try fixture.manager.startBranch(
                "feature/resume-slot", in: context, slot: "tree-1"
            )
        }
    }

    @Test
    func testExplicitSlotSelection() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        let selected = try fixture.manager.createBranch(
            "feature/selected", from: "main", in: context, slot: "tree-2"
        )
        #expect(selected.name == "tree-2")

        try fixture.run("git", ["branch", "feature/existing"], at: fixture.repository)
        let switched = try fixture.manager.switchBranch(
            "feature/existing", in: context, slot: "tree-1"
        )
        #expect(switched.name == "tree-1")
    }

    @Test
    func explicitSlotMustBeIdle() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        let active = try fixture.manager.createBranch(
            "feature/active", from: "main", in: context, slot: "tree-2"
        )
        #expect(throws: TreepoolError.self) {
            try fixture.manager.createBranch(
                "feature/another", from: "main", in: context, slot: active.name
            )
        }
    }

    @Test
    func testDirtySlotCannotBeReleased() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/dirty", from: "main", in: context)
        try Data("not committed\n".utf8).write(
            to: URL(fileURLWithPath: active.path).appendingPathComponent("dirty.txt")
        )
        #expect(throws: TreepoolError.self) { try fixture.manager.release("feature/dirty", in: context) }
    }

    @Test(arguments: [false, true])
    func forceReleaseDiscardsTrackedEditsAndDeletions(fromCurrentDirectory: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.commitFile("deleted.txt", contents: "keep\n", message: "add file")
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/force", from: "main", in: context)
        let root = URL(fileURLWithPath: active.path)
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try Data("cache\n".utf8).write(to: root.appendingPathComponent("cache.tmp"))
        let exclude = context.commonGitDirectory.appendingPathComponent("info/exclude")
        try Data("cache.tmp\n".utf8).write(to: exclude)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(throws: TreepoolError.self) {
            try fixture.manager.release(active.name, in: context)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "changed\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted.txt").path))

        let released = if fromCurrentDirectory {
            try fixture.manager.releaseCurrent(at: nested, in: context, force: true)
        } else {
            try fixture.manager.release(active.name, in: context, force: true)
        }
        #expect(released.detached && released.clean)
        #expect(released.head == active.head)
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "hello\n")
        #expect(try String(contentsOf: root.appendingPathComponent("deleted.txt"), encoding: .utf8) == "keep\n")
        #expect(try String(contentsOf: root.appendingPathComponent("cache.tmp"), encoding: .utf8) == "cache\n")
        #expect(try fixture.run("git", ["rev-parse", "refs/heads/feature/force"], at: root).stdout == active.head)
    }

    @Test(arguments: ["staged", "untracked"])
    func forceReleaseRefusesProtectedChangesBeforeDiscardingAnything(kind: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/protected", from: "main", in: context)
        let root = URL(fileURLWithPath: active.path)
        if kind == "staged" {
            try Data("staged\n".utf8).write(to: root.appendingPathComponent("README.md"))
            try fixture.run("git", ["add", "README.md"], at: root)
        } else {
            try Data("untracked\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        }
        try Data("unstaged\n".utf8).write(to: root.appendingPathComponent("README.md"))
        let before = try fixture.run("git", ["status", "--porcelain"], at: root).stdout

        #expect(throws: TreepoolError.self) {
            try fixture.manager.release(active.name, in: context, force: true)
        }
        #expect(try fixture.run("git", ["status", "--porcelain"], at: root).stdout == before)
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "unstaged\n")
        #expect(try fixture.run("git", ["branch", "--show-current"], at: root).stdout == "feature/protected")
        if kind == "staged" {
            #expect(try fixture.run("git", ["show", ":README.md"], at: root).stdout == "staged")
        } else {
            #expect(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8) == "untracked\n")
        }
    }

    @Test
    func forceReleaseRunsHooksBeforeDiscardingChanges() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            hooks: .init(preRelease: ["printf generated > README.md"])
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        let active = try fixture.manager.createBranch("feature/hook-force", from: "main", in: context)
        let released = try fixture.manager.release(active.name, in: context, force: true)
        #expect(released.detached && released.clean)
        #expect(try String(contentsOfFile: active.path + "/README.md", encoding: .utf8) == "hello\n")
    }

    @Test
    func testCurrentSlotReleaseUsesWorktreeRoot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/current", from: "main", in: context)
        let nested = URL(fileURLWithPath: active.path).appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let released = try fixture.manager.releaseCurrent(at: nested, in: context)
        #expect(released.name == active.name)
        #expect(released.detached)
    }

    @Test
    func testRepeatedInitializationIsRefused() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        #expect(throws: TreepoolError.self) { try fixture.manager.initialize(at: fixture.repository, slotCount: 1) }
        let context = try fixture.manager.context(at: fixture.repository)
        #expect(context.config.pool.size == 2)
        #expect(try fixture.manager.list(in: context).filter(\.isPoolSlot).count == 2)
    }

    @Test
    func testSetupProvisionsCommittedPolicy() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.writeConfig(.init(
            pool: .init(size: 2, root: "../sample.worktrees")
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        #expect(try fixture.manager.setup(in: context, dryRun: true).created.count == 2)
        #expect(try fixture.manager.list(in: context).filter(\.isPoolSlot).isEmpty)
        #expect(try fixture.manager.setup(in: context).created.count == 2)
        #expect(try fixture.manager.list(in: context).filter(\.isPoolSlot).count == 2)
    }

    @Test
    func testSetupReportsExtras() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees")
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        let result = try fixture.manager.setup(in: context)
        #expect(result.retained.count == 1)
        #expect(result.extras.count == 1)
        #expect(try fixture.run("git", ["worktree", "list", "--porcelain"], at: fixture.repository)
            .stdout.contains("tree-2"))
    }

    @Test
    func testRepairMissingSlot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let slot = try #require(try fixture.manager.list(in: context).first(where: \.isPoolSlot))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: slot.path))
        #expect(throws: TreepoolError.self) { try fixture.manager.setup(in: context) }
        let result = try fixture.manager.repair(in: context)
        #expect(result.repaired.count == 1)
        #expect(FileManager.default.fileExists(atPath: slot.path))
        #expect(try fixture.manager.list(in: context).first(where: \.isPoolSlot)?.clean == true)
    }

    @Test
    func testInvalidPatternIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 2, root: "../pool", pattern: "same")
        ))
        #expect(throws: TreepoolError.self) { try fixture.manager.context(at: fixture.repository) }
    }

    @Test
    func testMissingBaseBranchDefaultsToEmpty() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try Data(#"{"schemaVersion":1,"remote":"origin","pool":{"size":1,"root":"..\/sample.worktrees","pattern":"tree-{index}"}}"#.utf8)
            .write(to: fixture.repository.appendingPathComponent(".twt.json"))
        let config = try fixture.manager.context(at: fixture.repository).config
        #expect(config.baseBranch == "")
        #expect(config.fingerprint == nil)
        #expect(config.copyPatterns.isEmpty)
        #expect(config.hooks.postAssign.isEmpty)
        #expect(config.hooks.preRelease.isEmpty)
    }

    @Test
    func testExplicitBaseWorksWhenConfiguredBaseIsEmpty() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "",
            pool: .init(size: 1, root: "../sample.worktrees")
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        let active = try fixture.manager.createBranch("feature/explicit", from: "main", in: context)
        #expect(active.branch == "feature/explicit")
    }

    @Test
    func fingerprintRejectsWildcardPaths() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 2, root: "../sample.worktrees"),
            fingerprint: "Package*.resolved"
        ))

        #expect(throws: TreepoolError.self) {
            try fixture.manager.context(at: fixture.repository)
        }
    }

    @Test
    func fingerprintHashMatchTakesPriorityOverOldestSlot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.commitFile("dependencies.lock", contents: "base\n", message: "add lockfile")
        try fixture.run("git", ["switch", "-c", "feature/hash-target"], at: fixture.repository)
        try fixture.commitFile("dependencies.lock", contents: "target\n", message: "update lockfile")
        try fixture.run("git", ["switch", "main"], at: fixture.repository)

        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 2, root: "../sample.worktrees"),
            fingerprint: "dependencies.lock"
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        _ = try fixture.manager.switchBranch(
            "feature/hash-target", in: context, slot: "tree-2"
        )
        _ = try fixture.manager.release("tree-2", in: context)

        let selected = try fixture.manager.switchBranch("feature/hash-target", in: context)
        #expect(selected.name == "tree-2")
    }

    @Test
    func fingerprintDiffChoosesMostSimilarSlotWhenHashesDiffer() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.commitFile(
            "dependencies.lock",
            contents: "alpha\nbeta\ngamma\n",
            message: "add lockfile"
        )
        try fixture.run("git", ["branch", "feature/similarity-target"], at: fixture.repository)
        try fixture.run("git", ["switch", "-c", "feature/close"], at: fixture.repository)
        try fixture.commitFile(
            "dependencies.lock",
            contents: "alpha\nbeta\ndelta\n",
            message: "make close fingerprint"
        )
        try fixture.run("git", ["switch", "main"], at: fixture.repository)
        try fixture.run("git", ["switch", "-c", "feature/far"], at: fixture.repository)
        try fixture.commitFile(
            "dependencies.lock",
            contents: "red\ngreen\nblue\n",
            message: "make far fingerprint"
        )
        try fixture.run("git", ["switch", "main"], at: fixture.repository)

        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 2)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 2, root: "../sample.worktrees"),
            fingerprint: "dependencies.lock"
        ))
        let context = try fixture.manager.context(at: fixture.repository)
        _ = try fixture.manager.switchBranch("feature/far", in: context, slot: "tree-1")
        _ = try fixture.manager.release("tree-1", in: context)
        _ = try fixture.manager.switchBranch("feature/close", in: context, slot: "tree-2")
        _ = try fixture.manager.release("tree-2", in: context)

        let selected = try fixture.manager.switchBranch("feature/similarity-target", in: context)
        #expect(selected.name == "tree-2")
    }

    @Test
    func testCopyPatternsAreAppliedToAssignedSlot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try Data("TOKEN=abc\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".env.local")
        )
        let nested = fixture.repository.appendingPathComponent("config/local")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("{\"name\":\"sample\"}\n".utf8).write(
            to: nested.appendingPathComponent("agent.json")
        )
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            copyPatterns: [".env.local", "config/**/*.json"]
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let active = try fixture.manager.createBranch("feature/copy", from: "main", in: context)
        let slotRoot = URL(fileURLWithPath: active.path)
        let copiedEnv = slotRoot.appendingPathComponent(".env.local")
        let copiedConfig = slotRoot.appendingPathComponent("config/local/agent.json")

        #expect(FileManager.default.fileExists(atPath: copiedEnv.path))
        #expect(FileManager.default.fileExists(atPath: copiedConfig.path))
        #expect(try String(contentsOf: copiedEnv, encoding: .utf8) == "TOKEN=abc\n")
    }

    @Test
    func testCopyPatternsCannotEscapeRepositoryRoot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            copyPatterns: ["../secrets/*"]
        ))
        #expect(throws: TreepoolError.self) { try fixture.manager.context(at: fixture.repository) }
    }

    @Test
    func testCopyPatternsWarnWhenNoFilesMatch() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            copyPatterns: ["missing/**/*.txt"]
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let result = try fixture.manager.createBranchWithWarnings(
            "feature/missing-copy", from: "main", in: context
        )
        #expect(result.warnings.contains("copyPatterns pattern 'missing/**/*.txt' matched no files."))
        #expect(result.slot.branch == "feature/missing-copy")
    }

    @Test
    func testCopyPatternsOverwriteExistingFiles() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try Data("updated in primary\n".utf8).write(
            to: fixture.repository.appendingPathComponent("README.md")
        )
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            copyPatterns: ["README.md"]
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let result = try fixture.manager.createBranchWithWarnings(
            "feature/overwrite", from: "main", in: context
        )
        let readme = URL(fileURLWithPath: result.slot.path).appendingPathComponent("README.md")
        #expect(try String(contentsOf: readme, encoding: .utf8) == "updated in primary\n")
        #expect(result.warnings.isEmpty)
    }

    @Test
    func testPostAssignHookRunsInAssignedSlotAfterCopies() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try Data("TOKEN=abc\n".utf8).write(
            to: fixture.repository.appendingPathComponent(".env.local")
        )
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            copyPatterns: [".env.local"],
            hooks: .init(postAssign: ["test -f .env.local && pwd > hook.cwd"])
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let started = try fixture.manager.startBranch(
            "feature/post-assign-hook", from: "main", in: context
        )
        let slotRoot = URL(fileURLWithPath: started.slot.path)

        #expect(started.action == .created)
        #expect(try String(contentsOf: slotRoot.appendingPathComponent("hook.cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == slotRoot.path)
    }

    @Test
    func testPreReleaseHookRunsBeforeDetach() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            hooks: .init(preRelease: ["git symbolic-ref --short HEAD > ../pre-release-branch"])
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let active = try fixture.manager.createBranch("feature/pre-release-hook", from: "main", in: context)
        let released = try fixture.manager.release(active.name, in: context)

        #expect(released.detached)
        #expect(try String(
            contentsOf: URL(fileURLWithPath: active.path).deletingLastPathComponent()
                .appendingPathComponent("pre-release-branch"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "feature/pre-release-hook")
    }

    @Test
    func testHookFailureStopsLifecycleOperation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            hooks: .init(preRelease: ["printf hook-failed >&2; exit 7"])
        ))

        let context = try fixture.manager.context(at: fixture.repository)
        let active = try fixture.manager.createBranch("feature/failing-hook", from: "main", in: context)
        #expect(throws: TreepoolError.self) { try fixture.manager.release(active.name, in: context) }
        let readme = URL(fileURLWithPath: active.path).appendingPathComponent("README.md")
        try Data("keep unstaged\n".utf8).write(to: readme)
        #expect(throws: TreepoolError.self) {
            try fixture.manager.release(active.name, in: context, force: true)
        }
        #expect(try String(contentsOf: readme, encoding: .utf8) == "keep unstaged\n")
        #expect(try fixture.manager.list(in: context).first(where: { $0.name == active.name })?.branch == active.branch)
    }

    @Test
    func testEmptyHookCommandsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.writeConfig(.init(
            baseBranch: "main",
            pool: .init(size: 1, root: "../sample.worktrees"),
            hooks: .init(postAssign: [" "])
        ))

        #expect(throws: TreepoolError.self) { try fixture.manager.context(at: fixture.repository) }
    }

    @Test
    func testNestedBootstrapBranchName() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.run("git", ["branch", "release/stable"], at: fixture.repository)
        try fixture.run("git", ["update-ref", "refs/remotes/origin/release/stable", "HEAD"], at: fixture.repository)
        try fixture.run(
            "git", ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/release/stable"],
            at: fixture.repository
        )
        let expected = try fixture.run(
            "git", ["rev-parse", "release/stable"], at: fixture.repository
        ).stdout
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        #expect(context.config.baseBranch == "")
        #expect(try fixture.manager.list(in: context).first(where: \.isPoolSlot)?.head == expected)
    }

    @Test
    func testLocalRefPrecedence() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let oldHead = try fixture.run("git", ["rev-parse", "HEAD"], at: fixture.repository).stdout
        try Data("local\n".utf8).write(to: fixture.repository.appendingPathComponent("local.txt"))
        try fixture.run("git", ["add", "local.txt"], at: fixture.repository)
        try fixture.run("git", ["commit", "-m", "local advance"], at: fixture.repository)
        try fixture.run("git", ["update-ref", "refs/remotes/origin/main", oldHead], at: fixture.repository)
        let localHead = try fixture.run("git", ["rev-parse", "main"], at: fixture.repository).stdout
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        #expect(try fixture.manager.list(in: context).first(where: \.isPoolSlot)?.head == localHead)
    }
}

private final class Fixture {
    let temporaryDirectory: URL
    let repository: URL
    let manager = TreepoolManager()

    init() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("twt-tests-\(UUID().uuidString)")
        repository = temporaryDirectory.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try run("git", ["init", "-b", "main"], at: repository)
        try run("git", ["config", "user.name", "Treepool Tests"], at: repository)
        try run("git", ["config", "user.email", "tests@example.invalid"], at: repository)
        try Data("hello\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try run("git", ["add", "README.md"], at: repository)
        try run("git", ["commit", "-m", "initial"], at: repository)
    }

    func cleanup() { try? FileManager.default.removeItem(at: temporaryDirectory) }

    func writeConfig(_ config: TreepoolConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(
            to: repository.appendingPathComponent(".twt.json"),
            options: .atomic
        )
    }

    func commitFile(_ path: String, contents: String, message: String) throws {
        try Data(contents.utf8).write(to: repository.appendingPathComponent(path))
        try run("git", ["add", "--", path], at: repository)
        try run("git", ["commit", "-m", message], at: repository)
    }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], at directory: URL) throws -> CommandResult {
        try ProcessRunner.run(executable, arguments, directory: directory, allowFailure: true)
    }
}
