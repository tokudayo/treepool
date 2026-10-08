#if os(macOS)
import AppKit
import SwiftUI
import TreepoolCore
import UniformTypeIdentifiers

@MainActor
final class MenuStore: ObservableObject {
    @Published var repositories: [RepositorySnapshot] = []
    @Published var repositoryFailures: [RepositoryFailure] = []
    @Published var errorMessage: String?
    @Published var openApplications: [OpenApplication] = []

    private let manager = TreepoolManager()
    private let defaultsKey = "favoriteRepositories"
    private let openApplicationsDefaultsKey = "openWithApplicationPaths"
    private let defaultApplicationBundleIdentifier = "com.apple.finder"
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var stickyErrorMessage: String?

    init() {
        loadOpenApplications()
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let paths = favoritePaths
        let manager = manager

        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            var snapshots: [RepositorySnapshot] = []
            var failures: [RepositoryFailure] = []
            for path in paths {
                guard !Task.isCancelled else { return }
                do {
                    let context = try manager.context(at: URL(fileURLWithPath: path))
                    snapshots.append(RepositorySnapshot(
                        id: context.mainRoot.path,
                        context: context,
                        worktrees: try manager.list(in: context)
                    ))
                } catch {
                    failures.append(.init(path: path, message: String(describing: error)))
                }
            }
            await self?.applyRefresh(
                snapshots: snapshots,
                failures: failures,
                generation: generation
            )
        }
    }

    func addRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose a repository configured with Treepool"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            addFavorite(try manager.context(at: url))
        } catch TreepoolError.missingConfig {
            errorMessage = "This repository is not configured. Run 'twt init' in the repository, then add it again."
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func remove(_ repository: RepositorySnapshot) {
        saveFavorites(favoritePaths.filter { $0 != repository.context.mainRoot.path })
    }

    func removeFailure(_ failure: RepositoryFailure) {
        saveFavorites(favoritePaths.filter { $0 != failure.path })
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func canRelease(_ slot: WorktreeInfo) -> Bool {
        slot.isPoolSlot && slot.exists && !slot.detached
    }

    func requestRelease(_ slot: WorktreeInfo, in repository: RepositorySnapshot) {
        let current: WorktreeInfo
        do {
            guard let found = try manager.list(in: repository.context).first(where: { $0.path == slot.path }),
                  canRelease(found) else {
                refresh()
                return
            }
            current = found
        } catch {
            errorMessage = String(describing: error)
            return
        }
        let alert = NSAlert()
        alert.messageText = current.clean ? "Release \(current.name)?" : "Force release \(current.name)?"
        alert.informativeText = if !current.clean {
            "This slot has uncommitted changes. Force Release permanently discards unstaged changes to tracked files and returns the slot to the pool. Staged changes and untracked files block release and are kept. The branch and its commits are kept."
        } else if let branch = current.branch {
            "The slot detaches from '\(branch)' and returns to the pool. The branch and its commits are kept."
        } else {
            "The slot detaches and returns to the pool. Branches and commits are kept."
        }
        alert.alertStyle = .warning
        if current.clean {
            alert.addButton(withTitle: "Release Slot")
            alert.addButton(withTitle: "Abort")
        } else {
            alert.addButton(withTitle: "Abort")
            alert.addButton(withTitle: "Force Release")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == (current.clean ? .alertFirstButtonReturn : .alertSecondButtonReturn) else { return }
        release(current, in: repository, force: !current.clean)
    }

    @discardableResult
    func configureOpenApplications() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose applications for Open In"
        panel.message = "The selected applications will be added for every Treepool worktree."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return false }
        saveOpenApplications(openApplications.map(\.url) + panel.urls)
        return true
    }

    func removeOpenApplications(identifiedBy ids: Set<OpenApplication.ID>) {
        let remaining = openApplications.filter { !ids.contains($0.id) }.map(\.url)
        if remaining.isEmpty,
           let finder = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: defaultApplicationBundleIdentifier
           ) {
            saveOpenApplications([finder])
        } else {
            saveOpenApplications(remaining)
        }
    }

    func open(_ directory: URL, with application: OpenApplication) {
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: application.url,
            configuration: .init()
        ) { [weak self] _, error in
            guard let error else { return }
            let message = "Could not open \(directory.lastPathComponent) in \(application.name): \(error.localizedDescription)"
            Task { @MainActor in self?.errorMessage = message }
        }
    }

    private func applyRefresh(
        snapshots: [RepositorySnapshot],
        failures: [RepositoryFailure],
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }
        repositories = snapshots
        repositoryFailures = failures
        errorMessage = stickyErrorMessage
        stickyErrorMessage = nil
    }

    private func addFavorite(_ context: RepositoryContext) {
        var paths = favoritePaths
        if !paths.contains(context.mainRoot.path) { paths.append(context.mainRoot.path) }
        saveFavorites(paths)
    }

    private func saveFavorites(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        refresh()
    }

    private func release(_ slot: WorktreeInfo, in repository: RepositorySnapshot, force: Bool) {
        let manager = manager
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try manager.release(slot.path, in: repository.context, force: force)
                await self?.finishRelease(message: nil)
            } catch {
                await self?.finishRelease(message: String(describing: error))
            }
        }
    }

    private func finishRelease(message: String?) {
        stickyErrorMessage = message
        refresh()
    }

    private func loadOpenApplications() {
        if let paths = UserDefaults.standard.stringArray(forKey: openApplicationsDefaultsKey) {
            openApplications = applications(at: paths.map(URL.init(fileURLWithPath:)))
            return
        }
        let defaults = [defaultApplicationBundleIdentifier].compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        saveOpenApplications(defaults)
    }

    private func saveOpenApplications(_ urls: [URL]) {
        let applications = applications(at: urls)
        UserDefaults.standard.set(applications.map(\.url.path), forKey: openApplicationsDefaultsKey)
        openApplications = applications
    }

    private func applications(at urls: [URL]) -> [OpenApplication] {
        Array(Set(urls.map(\.standardizedFileURL)))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(OpenApplication.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var favoritePaths: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }
}
#endif
