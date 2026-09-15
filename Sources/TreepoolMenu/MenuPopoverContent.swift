#if os(macOS)
import AppKit
import SwiftUI
import TreepoolCore

struct MenuPopoverContent: View {
    @ObservedObject var store: MenuStore
    @State private var expandedRepositoryIDs: Set<String> = []
    @State private var hoveredRepositoryID: String?
    @State private var isManagingOpenApplications = false

    @ViewBuilder
    var body: some View {
        VStack(spacing: 0) {
            repositoryList
            if let error = store.errorMessage { errorBanner(error) }
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

    @ViewBuilder
    private var repositoryList: some View {
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
                    ForEach(store.repositories, content: repositorySection)
                    ForEach(store.repositoryFailures, content: failedRepositorySection)
                }
                .padding(14)
            }
            .frame(maxHeight: 420)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        Group {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            repositoryHeader(repository)
            if expandedRepositoryIDs.contains(repository.id) {
                ForEach(repository.worktrees) { slot in
                    worktreeRow(slot, in: repository)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func repositoryHeader(_ repository: RepositorySnapshot) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                toggle(repository)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expandedRepositoryIDs.contains(repository.id) ? "Hide worktrees" : "Show worktrees")
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())

            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(repository.context.mainRoot.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.trailing, 56)
            .allowsHitTesting(false)

            Menu {
                Button("Remove Repository", role: .destructive) { store.remove(repository) }
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
    }

    private func toggle(_ repository: RepositorySnapshot) {
        if expandedRepositoryIDs.contains(repository.id) {
            expandedRepositoryIDs.remove(repository.id)
        } else {
            expandedRepositoryIDs.insert(repository.id)
        }
    }

    private func worktreeRow(_ slot: WorktreeInfo, in repository: RepositorySnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(for: slot))
                .foregroundStyle(statusColor(for: slot))
                .font(.body.weight(.medium))
                .frame(width: 16)

            Button {
                reveal(slot.path)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name).font(.subheadline).foregroundStyle(.primary)
                    Text(slot.branch ?? "Idle").font(.caption).foregroundStyle(.secondary)
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

            slotActions(slot, in: repository)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 8))
    }

    private func slotActions(_ slot: WorktreeInfo, in repository: RepositorySnapshot) -> some View {
        Menu {
            Button("Reveal in Finder") { reveal(slot.path) }
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
            Button("Configure Apps…") { isManagingOpenApplications = true }
            if store.canRelease(slot) {
                Divider()
                Button("Release Slot…", role: .destructive) {
                    store.requestRelease(slot, in: repository)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func repositoryHeaderBackground(_ repository: RepositorySnapshot) -> AnyShapeStyle {
        hoveredRepositoryID == repository.id
            ? AnyShapeStyle(.tint.opacity(0.16))
            : AnyShapeStyle(Color.clear)
    }

    private var footer: some View {
        HStack {
            Button("Add Repository…") { store.addRepository() }
            Spacer()
            Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Refresh now")
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .font(.subheadline)
        .padding(12)
    }

    private func statusIcon(for slot: WorktreeInfo) -> String {
        slot.exists
            ? (slot.clean
                ? (slot.detached ? "circle" : "checkmark.circle.fill")
                : "exclamationmark.triangle.fill")
            : "xmark.circle.fill"
    }

    private func statusLabel(for slot: WorktreeInfo) -> String {
        slot.exists ? (slot.clean ? (slot.detached ? "Idle" : "Active") : "Dirty") : "Missing"
    }

    private func statusColor(for slot: WorktreeInfo) -> Color {
        slot.exists ? (slot.clean ? (slot.detached ? .secondary : .green) : .orange) : .red
    }
}
#endif
