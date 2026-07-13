#if os(macOS)
import AppKit
import SwiftUI
import TreepoolCore
import UniformTypeIdentifiers

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

private func treepoolSymbolImage(for appearance: NSAppearance) -> NSImage? {
    let variant = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? "Treepool-symbol-on-dark"
        : "Treepool-symbol-on-light"
    let url = Bundle.main.url(forResource: variant, withExtension: "png")
        ?? Bundle.module.url(forResource: variant, withExtension: "png")
    guard let url,
          let image = NSImage(contentsOf: url) else {
        return nil
    }

    image.size = NSSize(width: 18, height: 18)
    image.accessibilityDescription = "Treepool"
    return image
}

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
                    snapshots.append(
                        RepositorySnapshot(
                            id: context.mainRoot.path,
                            context: context,
                            worktrees: try manager.list(in: context)
                        )
                    )
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

    private func applyRefresh(
        snapshots: [RepositorySnapshot],
        failures: [RepositoryFailure],
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }
        repositories = snapshots
        repositoryFailures = failures
        errorMessage = nil
    }

    func addRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose a repository configured with Treepool"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let context = try manager.context(at: url)
            addFavorite(context)
        } catch TreepoolError.missingConfig {
            errorMessage = "This repository is not configured. Run 'twt init' in the repository, then add it again."
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func addFavorite(_ context: RepositoryContext) {
        var paths = favoritePaths
        if !paths.contains(context.mainRoot.path) {
            paths.append(context.mainRoot.path)
            UserDefaults.standard.set(paths, forKey: defaultsKey)
        }
        refresh()
    }

    func remove(_ repository: RepositorySnapshot) {
        UserDefaults.standard.set(
            favoritePaths.filter { $0 != repository.context.mainRoot.path },
            forKey: defaultsKey
        )
        refresh()
    }

    func removeFailure(_ failure: RepositoryFailure) {
        UserDefaults.standard.set(
            favoritePaths.filter { $0 != failure.path },
            forKey: defaultsKey
        )
        refresh()
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
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
        let remaining = openApplications
            .filter { !ids.contains($0.id) }
            .map(\.url)
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
        ) { _, error in
            if let error {
                let message = "Could not open \(directory.lastPathComponent) in \(application.name): \(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    self?.errorMessage = message
                }
            }
        }
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
        Array(Set(urls.map { $0.standardizedFileURL }))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(OpenApplication.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var favoritePaths: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }
}

@main
struct TreepoolMenuApp: App {
    @NSApplicationDelegateAdaptor(MenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MenuStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuPopoverContent(store: store))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Treepool"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.statusItem?.button?.image = treepoolSymbolImage(for: app.effectiveAppearance)
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover(sender)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            monitorOutsideClicks()
            store.refresh()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        removeOutsideClickMonitor()
    }

    private func monitorOutsideClicks() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover(nil)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

}

struct MenuPopoverContent: View {
    @ObservedObject var store: MenuStore
    @State private var expandedRepositoryIDs: Set<String> = []
    @State private var hoveredRepositoryID: String?
    @State private var isManagingOpenApplications = false

    @ViewBuilder
    var body: some View {
        VStack(spacing: 0) {
            if store.repositories.isEmpty && store.repositoryFailures.isEmpty {
                ContentUnavailableView(
                    "No repositories yet",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a repository to see its worktree pool.")
                )
                .frame(width: 340, height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.repositories) { repository in
                            repositorySection(repository)
                        }
                        ForEach(store.repositoryFailures) { failure in
                            failedRepositorySection(failure)
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 420)
            }

            if let error = store.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .sheet(isPresented: $isManagingOpenApplications) {
            OpenApplicationManager(
                store: store,
                isPresented: $isManagingOpenApplications
            )
        }
    }

    private func failedRepositorySection(_ failure: RepositoryFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: failure.path).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Remove") { store.removeFailure(failure) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 8))
    }

    private func repositorySection(_ repository: RepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .trailing) {
                Button {
                    toggle(repository)
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expandedRepositoryIDs.contains(repository.id) ? "Hide worktrees" : "Show worktrees")
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())

                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(repository.context.mainRoot.lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.trailing, 56)
                .allowsHitTesting(false)

                Menu {
                    Button("Remove Repository", role: .destructive) {
                        store.remove(repository)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
            .background(repositoryHeaderBackground(repository), in: .rect(cornerRadius: 10))
            .onHover { hoveredRepositoryID = $0 ? repository.id : nil }

            if expandedRepositoryIDs.contains(repository.id) {
                ForEach(repository.worktrees) { slot in
                    worktreeRow(slot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ repository: RepositorySnapshot) {
        if expandedRepositoryIDs.contains(repository.id) {
            expandedRepositoryIDs.remove(repository.id)
        } else {
            expandedRepositoryIDs.insert(repository.id)
        }
    }

    private func worktreeRow(_ slot: WorktreeInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(for: slot))
                .foregroundStyle(statusColor(for: slot))
                .font(.body.weight(.medium))
                .frame(width: 16)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.path)])
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(slot.branch ?? "Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            Text(statusLabel(for: slot))
                .font(.caption2.weight(.medium))
                .foregroundStyle(statusColor(for: slot))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(statusColor(for: slot).opacity(0.12), in: Capsule())

            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.path)])
                }
                Button("Copy Path") { store.copyPath(slot.path) }
                Divider()
                Section("Open In") {
                    if store.openApplications.isEmpty {
                        Text("No applications configured")
                    } else {
                        ForEach(store.openApplications) { application in
                            Button(application.name) {
                                store.open(URL(fileURLWithPath: slot.path), with: application)
                            }
                        }
                    }
                }
                Divider()
                Button("Configure Apps…") {
                    isManagingOpenApplications = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 8))
    }

    private func repositoryHeaderBackground(_ repository: RepositorySnapshot) -> AnyShapeStyle {
        if hoveredRepositoryID == repository.id {
            return AnyShapeStyle(.tint.opacity(0.16))
        }
        return AnyShapeStyle(Color.clear)
    }

    private var footer: some View {
        HStack {
            Button("Add Repository…") { store.addRepository() }
            Spacer()
            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.subheadline)
        .padding(12)
    }

    private func statusIcon(for slot: WorktreeInfo) -> String {
        slot.exists
            ? (slot.clean ? (slot.detached ? "circle" : "checkmark.circle.fill") : "exclamationmark.triangle.fill")
            : "xmark.circle.fill"
    }

    private func statusLabel(for slot: WorktreeInfo) -> String {
        slot.exists ? (slot.clean ? (slot.detached ? "Idle" : "Active") : "Dirty") : "Missing"
    }

    private func statusColor(for slot: WorktreeInfo) -> Color {
        slot.exists ? (slot.clean ? (slot.detached ? .secondary : .green) : .orange) : .red
    }
}

struct OpenApplicationManager: View {
    @ObservedObject var store: MenuStore
    @Binding var isPresented: Bool
    @State private var selection: Set<OpenApplication.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            List(store.openApplications, selection: $selection) { application in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(application.name)
                }
                .tag(application.id)
            }
            .frame(width: 360, height: 200)

            Divider()

            HStack {
                Button {
                    if store.configureOpenApplications() {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .help("Add applications")

                Button {
                    store.removeOpenApplications(identifiedBy: selection)
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .disabled(selection.isEmpty)
                .help("Remove selected applications")

                Spacer()

                Button("Done") { isPresented = false }
            }
            .padding(12)
        }
        .frame(width: 360)
    }
}
#endif
