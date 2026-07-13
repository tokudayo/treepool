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
    func testDirtySlotCannotBeReleased() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let context = try fixture.manager.initialize(at: fixture.repository, slotCount: 1)
        let active = try fixture.manager.createBranch("feature/dirty", from: "main", in: context)
        try Data("not committed\n".utf8).write(
            to: URL(fileURLWithPath: active.path).appendingPathComponent("dirty.txt")
        )
        #expect(throws: TreepoolError.self) { try fixture.manager.release("feature/dirty", in: context) }
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
        #expect(try fixture.manager.context(at: fixture.repository).config.baseBranch == "")
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

    @discardableResult
    func run(_ executable: String, _ arguments: [String], at directory: URL) throws -> CommandResult {
        try ProcessRunner.run(executable, arguments, directory: directory, allowFailure: true)
    }
}
