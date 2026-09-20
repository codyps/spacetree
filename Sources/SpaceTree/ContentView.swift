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
                DashboardToolbar()
                Divider()
                DashboardView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DashboardToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 15))
                Text("SpaceTree")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(model.visibleTargets.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Divider().frame(height: 18)

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

            volumeFilters

            Spacer(minLength: 8)

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
        .frame(height: 42)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var volumeFilters: some View {
        if model.timeMachineTargetCount > 0 || model.diskImageTargetCount > 0 || model.auxiliaryTargetCount > 0 {
            Menu {
                if model.timeMachineTargetCount > 0 {
                    Toggle("Time Machine (\(model.timeMachineTargetCount))", isOn: Binding(
                        get: { model.showTimeMachineMounts },
                        set: { model.showTimeMachineMounts = $0 }
                    ))
                }
                if model.diskImageTargetCount > 0 {
                    Toggle("Disk images (\(model.diskImageTargetCount))", isOn: Binding(
                        get: { model.showDiskImageMounts },
                        set: { model.showDiskImageMounts = $0 }
                    ))
                }
                if model.auxiliaryTargetCount > 0 {
                    Toggle("Developer/system (\(model.auxiliaryTargetCount))", isOn: Binding(
                        get: { model.showAuxiliaryMounts },
                        set: { model.showAuxiliaryMounts = $0 }
                    ))
                }
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .help("Choose which mounted filesystems to show")
        }
    }
}

private struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
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
        case .restoring:
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Restoring previous scan")
                    Button("Scan", action: target.scan)
                        .buttonStyle(.borderedProminent)
                        .disabled(!target.isAvailable)
                }
                Text(target.restorationStage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 330, height: 16, alignment: .trailing)
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
                ScanElapsedTime(target: target)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 330, alignment: .trailing)
                if let estimate = target.scanTimeEstimate {
                    VStack(alignment: .leading, spacing: 3) {
                        if let fraction = estimate.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .accessibilityLabel("Estimated scan progress")
                        } else {
                            ProgressView().progressViewStyle(.linear)
                                .accessibilityLabel("Scanning")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                Text(estimate.timeRemainingLabel(at: context.date))
                                Spacer(minLength: 4)
                                if let fraction = estimate.fraction {
                                    Text("≈\(Int(fraction * 100))%")
                                }
                            }
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 330)
                    .help("\(estimate.budget?.basis ?? "Waiting for a workload estimate"). Estimates adapt to scan speed and reserve time for finishing. Permissions, snapshots, clones, and filesystem changes can affect accuracy.")
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
                        ScanElapsedTime(target: target)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        return "\(root.fileCount.formatted()) files"
    }
}

private struct ScanElapsedTime: View {
    let target: ScanTarget

    var body: some View {
        Group {
            if target.state == .scanning, let startedAt = target.scanStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Elapsed \(formatted(context.date.timeIntervalSince(startedAt)))")
                }
            } else if let duration = target.scanDuration {
                Text("Scanned in \(formatted(duration))")
            }
        }
        .monospacedDigit()
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
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
                                target: target,
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

                FileOutlineView(target: target, revealRequest: revealRequest)
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

            if !target.trashedNodeIDs.isEmpty {
                Text("\(target.trashedNodeIDs.count) trashed · totals pending")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Update", action: target.rescan)
                    .disabled(target.state == .scanning)
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
                ScanElapsedTime(target: target)
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
            Text("Hover for individual files · open folders for detail").foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }
}
