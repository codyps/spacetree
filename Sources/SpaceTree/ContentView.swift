import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            Divider()
            if let target = model.viewingTarget {
                ExplorerView(target: target)
            } else {
                DashboardView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ToolbarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                Text("SpaceTree")
                    .font(.system(size: 16, weight: .bold))
            }
            .padding(.leading, 12)

            Divider().frame(height: 22)

            if let target = model.viewingTarget {
                Button(action: model.showDashboard) {
                    Label("All scans", systemImage: "chevron.left")
                }
                Text(target.name)
                    .font(.headline)
                    .lineLimit(1)
                if target.state == .scanning {
                    ProgressView().controlSize(.small)
                } else if target.hasFilesystemChanges {
                    Label("Changes detected", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if target.root != nil {
                    @Bindable var target = target
                    TextField("Filter this folder", text: $target.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                    Button(action: target.revealSelected) {
                        Label("Reveal", systemImage: "scope")
                    }
                    .disabled(target.selected == nil)
                }
            } else {
                Button(action: model.chooseFolder) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button(action: model.scanHome) {
                    Label("Add Home", systemImage: "house")
                }

                Button(action: model.refreshMountedItems) {
                    Label("Refresh Volumes", systemImage: "arrow.clockwise")
                }

                Spacer()

                if model.scanningCount > 0 {
                    Text("\(model.scanningCount) scanning")
                        .foregroundStyle(.secondary)
                    Button(role: .cancel, action: model.cancelAll) {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                }
                Button(action: model.scanAll) {
                    Label("Scan All", systemImage: "play.fill")
                }
                .disabled(model.visibleTargets.isEmpty)
            }
        }
        .controlSize(.small)
        .frame(height: 50)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
    }
}

private struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage and mounted filesystems")
                        .font(.system(size: 25, weight: .bold))
                    Text("Scan any combination at once. Results remain available until you rescan that item.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text("\(model.visibleTargets.count) items")
                        .foregroundStyle(.secondary)
                    if model.hiddenAuxiliaryCount > 0 {
                        Toggle("Show \(model.hiddenAuxiliaryCount) developer/system mounts", isOn: Binding(
                            get: { model.showAuxiliaryMounts },
                            set: { model.showAuxiliaryMounts = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            if model.visibleTargets.isEmpty {
                ContentUnavailableView {
                    Label("No mounted filesystems found", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Refresh mounted volumes or add a particular folder.")
                } actions: {
                    Button("Refresh", action: model.refreshMountedItems)
                    Button("Add Folder…", action: model.chooseFolder)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.visibleTargets) { target in
                            ScanTargetCard(target: target)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct ScanTargetCard: View {
    @Environment(AppModel.self) private var model
    @Bindable var target: ScanTarget

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.14))
                Image(systemName: target.isVolume ? "externaldrive.fill" : "folder.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(target.name)
                        .font(.headline)
                    if !target.isAvailable {
                        Text("Disconnected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(target.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(target.kindDescription)
                    if let total = target.totalCapacity, let available = target.availableCapacity {
                        Text("·")
                        Text("\((total - available).formattedByteCount) of \(total.formattedByteCount) used")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            stateView
                .frame(width: 330, alignment: .trailing)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch target.state {
        case .idle:
            HStack {
                Text("Not scanned").foregroundStyle(.secondary)
                Button("Scan", action: target.scan)
                    .buttonStyle(.borderedProminent)
                    .disabled(!target.isAvailable)
            }
        case .scanning:
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(target.progress.itemCount.formatted()) items")
                    Text("·")
                    Text(target.progress.bytesFound.formattedByteCount)
                    Button("Stop", role: .cancel, action: target.cancel)
                }
                Text(target.progress.currentPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300)
            }
        case .complete:
            HStack(spacing: 9) {
                if let root = target.root {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(root.allocatedBytes.formattedByteCount)
                            .font(.headline.monospacedDigit())
                        Text(completionDetail(root: root))
                            .font(.caption)
                            .foregroundStyle(target.hasFilesystemChanges ? .orange : .secondary)
                    }
                }
                Button("View") { model.show(target) }
                    .buttonStyle(.borderedProminent)
                Button(target.hasFilesystemChanges ? "Update" : "Check", action: target.rescan)
                    .disabled(!target.isAvailable)
            }
        case .failed(let message):
            HStack(spacing: 9) {
                Label {
                    Text(message)
                        .lineLimit(2)
                        .help(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: 230, alignment: .trailing)
                Button("Try Again", action: target.scan)
                    .disabled(!target.isAvailable)
            }
        }
    }

    private var iconColor: Color {
        guard target.isVolume else { return .blue }
        if target.kindDescription.localizedCaseInsensitiveContains("APFS") { return .purple }
        return .teal
    }

    private func completionDetail(root: NodeMetadata) -> String {
        if target.hasFilesystemChanges {
            return "Changes detected · \(root.fileCount.formatted()) files"
        }
        if let duration = target.scanDuration {
            return "\(root.fileCount.formatted()) files · \(duration.formatted(.number.precision(.fractionLength(1))))s"
        }
        return "\(root.fileCount.formatted()) files"
    }
}

private struct ExplorerView: View {
    @Bindable var target: ScanTarget

    var body: some View {
        HSplitView {
            SummarySidebar(target: target)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            VStack(spacing: 0) {
                BreadcrumbBar(target: target)
                VSplitView {
                    VStack(spacing: 8) {
                        LegendView()
                        if target.visibleChildren.isEmpty {
                            ContentUnavailableView(
                                target.searchText.isEmpty ? "This folder is empty" : "No matches",
                                systemImage: "square.grid.3x3"
                            )
                        } else {
                            if let tree = target.tree {
                                TreemapView(
                                    tree: tree,
                                    nodeIDs: target.visibleChildren.map(\.handle.nodeID),
                                    selectedID: target.selectedID,
                                    onSelect: target.select
                                )
                            }
                        }
                    }
                    .padding(10)
                    .frame(minHeight: 260)

                    FileListView(target: target)
                        .frame(minHeight: 180, idealHeight: 250)
                }
            }
        }
    }
}

private struct BreadcrumbBar: View {
    @Bindable var target: ScanTarget

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(target.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                    }
                    Button { target.open(node) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == 0 ? "externaldrive.fill" : "folder.fill")
                            Text(node.name)
                            Text(node.allocatedBytes.formattedByteCount).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct SummarySidebar: View {
    @Bindable var target: ScanTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let current = target.current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.name).font(.headline).lineLimit(2)
                    Text(current.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Divider()
                Metric(value: current.allocatedBytes.formattedByteCount, label: "Allocated size", alignment: .leading)
                Metric(value: current.fileCount.formatted(), label: "Files", alignment: .leading)
                Metric(value: max(0, current.directoryCount - 1).formatted(), label: "Folders", alignment: .leading)
                if current.duplicateReferenceCount > 0 {
                    Metric(value: current.duplicateReferenceCount.formatted(), label: "Hard-link refs not recounted", alignment: .leading)
                }
                if target.progress.unreadableCount > 0 {
                    Label("\(target.progress.unreadableCount) items could not be read", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Some macOS folders require Full Disk Access in System Settings → Privacy & Security.")
                }

                Divider()
                Text("Largest here")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(target.currentChildren.prefix(6))) { node in
                    Button { target.open(node) } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(FilePalette.color(for: node))
                                .frame(width: 9, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.name).lineLimit(1)
                                Text(node.allocatedBytes.formattedByteCount)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct LegendView: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(FilePalette.legend, id: \.0) { label, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                    Text(label)
                }
            }
            Spacer()
            Text("Every file is a tile · hover for details").foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }
}

private struct FileListView: View {
    @Bindable var target: ScanTarget

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: 90, alignment: .leading)
                Text("Items").frame(width: 70, alignment: .trailing)
                Text("Allocated").frame(width: 100, alignment: .trailing)
                Text("Modified").frame(width: 130, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            List(target.visibleChildren, selection: Binding(
                get: { target.selected?.id },
                set: { id in target.select(target.visibleChildren.first(where: { $0.id == id })) }
            )) { node in
                FileRow(node: node)
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { target.open(node) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

private struct FileRow: View {
    let node: NodeMetadata

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: node.isDirectory ? "folder.fill" : (node.isDuplicateReference ? "link" : "doc.fill"))
                    .foregroundStyle(FilePalette.color(for: node))
                Text(node.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(node.isDuplicateReference ? "Hard link" : node.fileExtension.capitalized)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(node.isDirectory ? node.fileCount.formatted() : "—")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(node.allocatedBytes.formattedByteCount)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Text(node.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.callout)
    }
}

private struct Metric: View {
    let value: String
    let label: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
