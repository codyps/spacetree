import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.viewingTarget {
                ExplorerToolbar(target: target)
                Divider()
                ExplorerView(target: target)
            } else {
                ToolbarView()
                Divider()
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
                HStack(alignment: .center, spacing: 14) {
                    Text("\(model.visibleTargets.count) items")
                        .foregroundStyle(.secondary)
                    if model.timeMachineTargetCount > 0 {
                        Toggle("Time Machine (\(model.timeMachineTargetCount))", isOn: Binding(
                            get: { model.showTimeMachineMounts },
                            set: { model.showTimeMachineMounts = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                    if model.diskImageTargetCount > 0 {
                        Toggle("Disk images (\(model.diskImageTargetCount))", isOn: Binding(
                            get: { model.showDiskImageMounts },
                            set: { model.showDiskImageMounts = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                    if model.auxiliaryTargetCount > 0 {
                        Toggle("Developer/system (\(model.auxiliaryTargetCount))", isOn: Binding(
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
                Image(systemName: iconName)
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
                        .monospacedDigit()
                        .frame(width: 130, alignment: .trailing)
                    Text("·")
                    Text(target.progress.bytesFound.formattedByteCount)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                    Button("Stop", role: .cancel, action: target.cancel)
                }
                // Both scan phases occupy the same single-line status slot.
                Group {
                    if let finishing = target.progress.finishing {
                        HStack(spacing: 8) {
                            Text("Finishing: \(finishing.stage)")
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Finishing: \(finishing.stage)")
                            ProgressView(value: Double(finishing.completed), total: Double(max(1, finishing.total)))
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                        }
                    } else {
                        Text(target.progress.currentPath)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 330, height: 16, alignment: .trailing)
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

    private var iconName: String {
        guard target.isVolume else { return "folder.fill" }
        if target.isTimeMachine { return "clock.arrow.circlepath" }
        if target.isDiskImage { return "opticaldisc" }
        return "externaldrive.fill"
    }

    private var iconColor: Color {
        guard target.isVolume else { return .blue }
        if target.isTimeMachine { return .cyan }
        if target.isDiskImage { return .indigo }
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
    @State private var revealRequest = 0

    var body: some View {
        VStack(spacing: 0) {
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
                                onSelect: { node in
                                    target.select(node)
                                    revealRequest += 1
                                }
                            )
                        }
                    }
                }
                .padding(10)
                .frame(minHeight: 260)

                FileListView(target: target, revealRequest: revealRequest)
                    .frame(minHeight: 180, idealHeight: 250)
            }
        }
    }
}

private struct ExplorerToolbar: View {
    @Environment(AppModel.self) private var model
    @Bindable var target: ScanTarget

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.showDashboard) {
                Label("All scans", systemImage: "square.grid.2x2")
            }
            .fixedSize()

            HStack(spacing: 4) {
                Button(action: target.goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!target.canGoBack)
                .help("Back (⌘[)")

                Button(action: target.goForward) {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!target.canGoForward)
                .help("Forward (⌘])")

                Button(action: target.goUp) {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(!target.canGoUp)
                .help("Enclosing Folder (⌘↑)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Divider().frame(height: 20)
            breadcrumbs
                .frame(minWidth: 100, maxWidth: .infinity)

            if target.state == .scanning {
                ProgressView().controlSize(.small)
            } else if target.hasFilesystemChanges {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Changes detected")
            }

            ScanInfoBar(target: target)
                .fixedSize()

            TextField("Filter this folder", text: $target.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button(action: target.revealSelected) {
                Label("Reveal", systemImage: "scope")
            }
            .labelStyle(.iconOnly)
            .help("Reveal selected item in Finder")
            .disabled(target.selected == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var breadcrumbs: some View {
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
                    .help(node.url.path)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct ScanInfoBar: View {
    @Bindable var target: ScanTarget

    var body: some View {
        if let current = target.current {
            HStack(spacing: 10) {
                Text(current.allocatedBytes.formattedByteCount)
                    .fontWeight(.semibold)
                    .help("Allocated size")
                Text("\(current.fileCount.formatted()) files")
                Text("\(max(0, current.directoryCount - 1).formatted()) folders")
                if current.duplicateReferenceCount > 0 {
                    Text("\(current.duplicateReferenceCount.formatted()) links")
                        .help("Hard-link references already counted elsewhere are not recounted.")
                }
                if target.progress.unreadableCount > 0 {
                    Label("\(target.progress.unreadableCount.formatted()) unreadable", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize()
                        .help("\(target.progress.unreadableCount.formatted()) items could not be read. Some macOS folders require Full Disk Access in System Settings → Privacy & Security.")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
    let revealRequest: Int
    @State private var expanded: Set<NodeID> = []

    private var rows: [FileTreeRow] {
        guard let tree = target.tree else { return [] }
        return FileTreeRow.visible(tree: tree, roots: target.visibleChildren.map(\.handle.nodeID), expanded: expanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("% of parent").frame(width: 130, alignment: .leading)
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

            ScrollViewReader { proxy in
                List(selection: Binding<NodeID?>(
                    get: { target.selectedID },
                    set: { target.selectedID = $0 }
                )) {
                    ForEach(rows) { row in
                        if let tree = target.tree {
                            let node = tree.metadata(for: row.id)
                            FileRow(node: node, depth: row.depth, fraction: tree.fractionOfParent(row.id),
                                    expanded: expanded.contains(row.id)) {
                                if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                            }
                            .tag(row.id)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { target.open(node) }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: target.selectedID, initial: true) { _, id in
                    revealSelection(using: proxy)
                }
                .onChange(of: revealRequest) { _, _ in revealSelection(using: proxy) }
                .onChange(of: target.tree?.generation) { _, _ in expanded.removeAll() }
            }
        }
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        guard let id = target.selectedID, let tree = target.tree else { return }
        expanded.formUnion(tree.breadcrumbs(to: id).dropLast())
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
        }
    }

}

private struct FileRow: View {
    let node: NodeMetadata
    let depth: Int
    let fraction: Double
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .opacity(node.isDirectory ? 1 : 0)
                .disabled(!node.isDirectory)
                .accessibilityLabel(expanded ? "Collapse folder" : "Expand folder")
                Image(systemName: node.isDirectory ? "folder.fill" : (node.isDuplicateReference ? "link" : "doc.fill"))
                    .foregroundStyle(FilePalette.color(for: node))
                Text(node.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                GeometryReader { geometry in
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(FilePalette.color(for: node))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: 8)
                Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: 130)
            .accessibilityLabel("\(fraction.formatted(.percent)) of parent folder")
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
