import SwiftUI

// Only visualization data: never attach a ScanTarget or live-file actions to
// these synthetic byte weights and backup-relative paths.
struct BackupMapData: Sendable {
    let tree: ScanTree
    let paths: [NodeID: String]
    let ids: [String: NodeID]
    let summaries: Set<NodeID>

    static func build(_ comparisons: [BackupComparison], metric: BackupMetric,
                      folder: String = "", search: String = "") throws -> BackupMapData {
        var weights: [String: Double] = [:]
        var summaryPaths: Set<String> = []
        let prefix = folder.isEmpty ? "" : folder + "/"
        for comparison in comparisons {
            for (index, change) in comparison.changes.enumerated() {
                if index.isMultiple(of: 512) { try Task.checkCancellation() }
                guard change.path == folder || change.path.hasPrefix(prefix),
                      search.isEmpty || change.path.localizedCaseInsensitiveContains(search) else { continue }
                let bytes = metric.bytes(change)
                guard bytes > 0 else { continue }
                weights[change.path, default: 0] += Double(bytes)
                if change.subtree == true { summaryPaths.insert(change.path) }
            }
        }
        var directoryPaths: Set<String> = [folder]
        for path in weights.keys {
            var current = (path as NSString).deletingLastPathComponent
            while current != folder && current.hasPrefix(prefix) && !current.isEmpty {
                if !directoryPaths.insert(current).inserted { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        var builder = ScanTreeBuilder(rootName: "Backup changes", rootURL: URL(fileURLWithPath: "/"))
        var ids: [String: NodeID] = [folder: builder.rootID]
        var paths: [NodeID: String] = [builder.rootID: folder]
        var summaries: Set<NodeID> = []
        for path in directoryPaths.sorted() where path != folder {
            try Task.checkCancellation()
            let parent = (path as NSString).deletingLastPathComponent
            guard let parentID = ids[parent] else { continue }
            let id = builder.addNode(parent: parentID, name: (path as NSString).lastPathComponent, kind: .directory,
                                     allocatedBytes: 0, logicalBytes: 0, modifiedAt: nil, identity: nil)
            ids[path] = id
            paths[id] = path
        }
        for path in weights.keys.sorted() {
            try Task.checkCancellation()
            let hasChildren = directoryPaths.contains(path)
            let parent = hasChildren ? path : (path as NSString).deletingLastPathComponent
            guard let parentID = ids[parent], let weight = weights[path] else { continue }
            // A subtree summary from one interval may coexist with individually
            // changed descendants in another. Preserve its weight as a separate
            // labeled leaf, never assign those bytes to guessed descendants.
            let isSummary = summaryPaths.contains(path)
            let name = hasChildren ? (isSummary ? "Subtree summary" : "File changes at this path")
                : (path as NSString).lastPathComponent + (isSummary ? " (subtree summary)" : "")
            let size = Int64(min(Double(Int64.max - 1024), weight))
            let id = builder.addNode(parent: parentID, name: name, kind: .file,
                                     allocatedBytes: size, logicalBytes: size, modifiedAt: nil, identity: nil)
            paths[id] = path
            if !hasChildren { ids[path] = id }
            if isSummary { summaries.insert(id) }
        }
        return BackupMapData(tree: try builder.finalize(), paths: paths, ids: ids, summaries: summaries)
    }
}

struct BackupChangeMap: View {
    let comparisons: [BackupComparison]
    let revision: Int
    let metric: BackupMetric
    let folder: String
    let search: String
    let selected: String?
    let select: (String) -> Void
    let drill: (String) -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var prepared: Prepared?
    @State private var hover: TreemapScene.Hit?
    @State private var preparing = false
    @State private var failure: String?
    @State private var owner = UUID()

    private struct Prepared {
        let data: BackupMapData
        let scene: TreemapScene
    }
    private struct Request: Hashable {
        let revision: Int
        let metric: BackupMetric
        let folder: String
        let search: String
        let width: Int
        let height: Int
        let scale: CGFloat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let request = Request(revision: revision, metric: metric, folder: folder, search: search,
                                      width: Int(bounds.width), height: Int(bounds.height), scale: displayScale)
                ZStack {
                    Color.black.opacity(0.28)
                    if let prepared {
                        TreemapBaseLayer(scene: prepared.scene, bounds: prepared.scene.bounds).equatable()
                            .frame(width: prepared.scene.bounds.width, height: prepared.scene.bounds.height)
                            .scaleEffect(x: bounds.width / max(1, prepared.scene.bounds.width),
                                         y: bounds.height / max(1, prepared.scene.bounds.height), anchor: .topLeading)
                        Canvas { context, _ in
                            let selectedRect = selected.flatMap { prepared.data.ids[$0] }.flatMap { prepared.scene.rect(for: $0) }
                            for rect in [selectedRect, hover?.rect].compactMap({ $0 }) {
                                context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
                            }
                        }.allowsHitTesting(false)
                    }
                    if preparing { ProgressView("Preparing change map…").padding(12).background(.regularMaterial) }
                    if let failure { Text(failure).font(.caption).padding().background(.regularMaterial) }
                }
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !preparing, let prepared else { return }
                    switch phase {
                    case .active(let point): hover = prepared.scene.hit(at: point)
                    case .ended: hover = nil
                    }
                }
                .onTapGesture(count: 2) { point in activate(point, open: true) }
                .onTapGesture { point in activate(point, open: false) }
                .task(id: request) { await prepare(in: bounds) }
            }
            Text(hoverLabel).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).frame(height: 16).textSelection(.enabled)
        }
        .frame(minHeight: 220)
        .accessibilityLabel("Hierarchical backup changes treemap. Folder groups contain child files. Use Largest contributors for keyboard selection.")
    }

    private var hoverLabel: String {
        guard let hover, let prepared, let path = prepared.data.paths[hover.entry.nodeID] else {
            return "Hover for a file path · double-click a folder or file to zoom into its folder"
        }
        return "\(path) · \(hover.entry.allocatedBytes.formattedByteCount)\(prepared.data.summaries.contains(hover.entry.nodeID) ? " · subtree summary; individual files unavailable" : "")"
    }

    private func activate(_ point: CGPoint, open: Bool) {
        guard !preparing, let prepared, let hit = prepared.scene.hit(at: point),
              let path = prepared.data.paths[hit.entry.nodeID] else { return }
        select(path)
        if open {
            let id = prepared.data.tree.kind(of: hit.entry.nodeID) == .directory
                ? hit.entry.nodeID : prepared.data.tree.parent(of: hit.entry.nodeID)
            if let id, let destination = prepared.data.paths[id], destination != folder { drill(destination) }
        }
    }

    @MainActor private func prepare(in bounds: CGRect) async {
        guard bounds.width > 0, bounds.height > 0 else { return }
        preparing = true
        failure = nil
        hover = nil
        let input = comparisons, selectedMetric = metric, selectedFolder = folder, query = search
        let worker = Task.detached(priority: .userInitiated) {
            try BackupMapData.build(input, metric: selectedMetric, folder: selectedFolder, search: query)
        }
        do {
            let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let scene = try await TreemapBuildCoordinator.shared.build(owner: owner, tree: data.tree,
                nodes: Array(data.tree.childIDs(of: data.tree.rootID)), bounds: bounds, scale: displayScale, onProgress: { _ in })
            try Task.checkCancellation()
            prepared = Prepared(data: data, scene: scene)
            preparing = false
        } catch is CancellationError {
            // The successor task owns the loading state.
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            preparing = false
        }
    }
}
