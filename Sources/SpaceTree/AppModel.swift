import AppKit
import CoreServices
import Observation
import SwiftUI

@MainActor
@Observable
final class ScanTarget: Identifiable {
    enum Kind: Equatable {
        case apfsContainer(volumeCount: Int, isInternal: Bool, isRemovable: Bool, isReadOnly: Bool)
        case volume(format: String, isInternal: Bool, isRemovable: Bool, isReadOnly: Bool)
        case folder
    }

    enum State: Equatable {
        case idle
        case restoring
        case scanning
        case complete
        case failed(String)
    }

    let id: String
    var url: URL
    var roots: [ScanRoot]
    var name: String
    var kind: Kind
    var totalCapacity: Int64?
    var availableCapacity: Int64?
    var isAvailable: Bool
    var isDiskImage: Bool
    var isTimeMachine: Bool
    var isAuxiliary: Bool
    let persistResults: Bool
    var state: State = .idle
    var restorationStage = "Checking for previous scan…"
    var progress: ScanProgress
    var tree: ScanTree? {
        didSet {
            guard tree?.generation != oldValue?.generation else { return }
            trashedNodeIDs.removeAll()
            backHistory.removeAll()
            forwardHistory.removeAll()
            currentID = tree?.rootID
            selectedID = nil
            searchText = ""
        }
    }
    private(set) var trashedNodeIDs: Set<NodeID> = []

    func isTrashed(_ id: NodeID) -> Bool {
        guard !trashedNodeIDs.isEmpty, let tree else { return false }
        var cursor: NodeID? = id
        while let node = cursor {
            if trashedNodeIDs.contains(node) { return true }
            cursor = tree.parent(of: node)
        }
        return false
    }

    func recordTrashed(_ node: NodeMetadata) {
        guard let tree, tree.contains(node.handle) else { return }
        trashedNodeIDs.insert(node.handle.nodeID)
        hasFilesystemChanges = true
        requiresFullRescan = true
        changedPaths.insert(node.url.deletingLastPathComponent().path)
        changedPathCount = changedPaths.count
        if let selectedID, isTrashed(selectedID) { self.selectedID = nil }
    }

    var currentID: NodeID?
    private var backHistory: [NodeID] = []
    private var forwardHistory: [NodeID] = []
    var selectedID: NodeID?
    var searchText = ""
    var scannedAt: Date?
    var scanDuration: TimeInterval?
    var scanStatistics: ScanStatistics?
    var statisticsSaveError: String?
    @ObservationIgnored private var statisticsRecorder: ScanStatisticsRecorder?
    var hasFilesystemChanges = false
    var changedPathCount = 0
    var changeTrackingAvailable = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var changeMonitor: FilesystemChangeMonitor?
    @ObservationIgnored private var changedPaths: Set<String> = []
    @ObservationIgnored private var requiresFullRescan = false

    init(
        id: String,
        url: URL,
        name: String,
        kind: Kind,
        roots: [ScanRoot]? = nil,
        totalCapacity: Int64? = nil,
        availableCapacity: Int64? = nil,
        isAvailable: Bool = true,
        isDiskImage: Bool = false,
        isTimeMachine: Bool = false,
        isAuxiliary: Bool = false,
        persistResults: Bool = true
    ) {
        self.id = id
        self.url = url
        self.roots = roots ?? [ScanRoot(url: url, name: name)]
        self.name = name
        self.kind = kind
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.isAvailable = isAvailable
        self.isDiskImage = isDiskImage
        self.isTimeMachine = isTimeMachine
        self.isAuxiliary = isAuxiliary
        self.persistResults = persistResults
        self.progress = ScanProgress(currentPath: url.path, itemCount: 0, bytesFound: 0, unreadableCount: 0)
    }

    var isVolume: Bool {
        switch kind {
        case .apfsContainer, .volume: return true
        case .folder: return false
        }
    }

    var kindDescription: String {
        switch kind {
        case .folder: return "Folder"
        case .apfsContainer(let volumeCount, let isInternal, let isRemovable, let isReadOnly):
            var parts = ["APFS container", "\(volumeCount) mounted \(volumeCount == 1 ? "volume" : "volumes")"]
            if isTimeMachine {
                parts.append("Time Machine")
            } else if isDiskImage {
                parts.append("Disk image")
            } else {
                parts.append(isInternal ? "Internal" : (isRemovable ? "Removable" : "External"))
            }
            if isReadOnly { parts.append("Read only") }
            return parts.joined(separator: " · ")
        case .volume(let format, let isInternal, let isRemovable, let isReadOnly):
            var parts = [format]
            if isTimeMachine {
                parts.append("Time Machine")
            } else if isDiskImage {
                parts.append("Disk image")
            } else {
                parts.append(isInternal ? "Internal" : (isRemovable ? "Removable" : "External"))
            }
            if isReadOnly { parts.append("Read only") }
            return parts.joined(separator: " · ")
        }
    }

    var root: NodeMetadata? {
        guard let tree else { return nil }
        return tree.metadata(for: tree.rootID)
    }

    var current: NodeMetadata? {
        guard let tree, let currentID else { return nil }
        return tree.metadata(for: currentID)
    }

    var selected: NodeMetadata? {
        guard let tree, let selectedID, !isTrashed(selectedID) else { return nil }
        return tree.metadata(for: selectedID)
    }

    var visibleChildren: [NodeMetadata] {
        let children = currentChildren
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return children }
        return children.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var currentChildren: [NodeMetadata] {
        guard let tree, let currentID else { return [] }
        return tree.children(of: currentID).map { tree.metadata(for: $0) }
    }

    var breadcrumbs: [NodeMetadata] {
        guard let tree, let currentID else { return [] }
        return tree.breadcrumbs(to: currentID).map { tree.metadata(for: $0) }
    }

    func scan() {
        endStatistics(outcome: "cancelled")
        task?.cancel()
        changeMonitor?.stop()
        changeMonitor = nil
        changeTrackingAvailable = false
        generation = UUID()
        let thisGeneration = generation
        let scanStartedAt = Date()
        let recorder = ScanStatisticsRecorder(targetID: id, roots: roots.map(\.url.path), mode: "full")
        statisticsRecorder = recorder
        let startingEventID = UInt64(FSEventsGetCurrentEventId())
        tree = nil
        currentID = nil
        selectedID = nil
        searchText = ""
        hasFilesystemChanges = false
        changedPathCount = 0
        changedPaths.removeAll()
        requiresFullRescan = false
        progress = ScanProgress(currentPath: url.path, itemCount: 0, bytesFound: 0, unreadableCount: 0)
        state = .scanning

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await DiskScanner.scan(
                    roots: roots,
                    displayName: name,
                    identifier: id,
                    statistics: recorder
                ) { [weak self] update in
                    await MainActor.run {
                        guard let self, self.generation == thisGeneration else { return }
                        self.progress = update
                    }
                }
                guard !Task.isCancelled, generation == thisGeneration else { return }
                finishScan(result, startedAt: scanStartedAt, eventID: startingEventID)
            } catch is CancellationError {
                guard generation == thisGeneration else { return }
                endStatistics(outcome: "cancelled")
                state = .idle
                task = nil
            } catch {
                guard generation == thisGeneration else { return }
                endStatistics(outcome: "failed", error: error.localizedDescription)
                state = .failed(error.localizedDescription)
                task = nil
            }
        }
    }

    func cancel() {
        guard state == .scanning || state == .restoring else { return }
        endStatistics(outcome: "cancelled")
        generation = UUID()
        task?.cancel()
        task = nil
        if tree == nil {
            state = .idle
        } else {
            state = .complete
            startChangeTracking(since: UInt64(FSEventsGetCurrentEventId()))
        }
    }

    func rescan() {
        if state == .complete, changeTrackingAvailable, !hasFilesystemChanges, !requiresFullRescan {
            scannedAt = Date()
            return
        }
        if state == .complete,
           changeTrackingAvailable,
           hasFilesystemChanges,
           !requiresFullRescan,
           !changedPaths.isEmpty,
           changedPaths.count <= 128,
           root?.duplicateReferenceCount == 0 {
            incrementalScan()
            return
        }
        scan()
    }

    func restoreSnapshot(
        load: @escaping @Sendable (String, @escaping @Sendable (String) -> Void) async -> ScanSnapshot? = {
            await SnapshotStore.load(targetID: $0, progress: $1)
        }
    ) {
        guard persistResults, state == .idle, tree == nil else { return }
        let expectedGeneration = generation
        restorationStage = "Checking for previous scan…"
        state = .restoring
        task = Task { [weak self] in
            guard let self else { return }
            let snapshot = await load(id) { [weak self] stage in
                Task { @MainActor [weak self] in
                    guard let self, generation == expectedGeneration, state == .restoring else { return }
                    restorationStage = stage
                }
            }
            guard !Task.isCancelled, generation == expectedGeneration, state == .restoring else { return }
            task = nil
            guard let snapshot else {
                state = .idle
                return
            }
            tree = snapshot.tree
            currentID = snapshot.tree.rootID
            progress = snapshot.progress
            scannedAt = snapshot.scannedAt
            scanDuration = snapshot.scanDuration
            scanStatistics = snapshot.statistics
            requiresFullRescan = snapshot.requiresMetadataRefresh
            state = .complete
            startChangeTracking(since: snapshot.fseventID)
        }
    }

    func open(_ node: NodeMetadata) {
        guard let tree, tree.contains(node.handle), !isTrashed(node.handle.nodeID) else { return }
        if node.isDirectory {
            guard currentID != node.handle.nodeID else { return }
            if let currentID { backHistory.append(currentID) }
            forwardHistory.removeAll()
            navigate(to: node.handle.nodeID)
        } else {
            selectedID = node.handle.nodeID
        }
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool {
        guard let tree, let currentID else { return false }
        return tree.parent(of: currentID) != nil
    }

    func goBack() {
        guard let destination = backHistory.popLast(), let currentID else { return }
        forwardHistory.append(currentID)
        navigate(to: destination)
    }

    func goForward() {
        guard let destination = forwardHistory.popLast(), let currentID else { return }
        backHistory.append(currentID)
        navigate(to: destination)
    }

    func goUp() {
        guard let tree, let currentID, let parent = tree.parent(of: currentID) else { return }
        open(tree.metadata(for: parent))
    }

    private func navigate(to destination: NodeID) {
        currentID = destination
        selectedID = nil
        searchText = ""
    }

    func select(_ node: NodeMetadata?) {
        selectedID = node?.handle.nodeID
    }

    func revealSelected() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selected.url])
    }

    private func startChangeTracking(since eventID: UInt64) {
        changeMonitor?.stop()
        let monitor = FilesystemChangeMonitor(paths: roots.map(\.url.path), since: eventID) { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasFilesystemChanges = true
                self.changedPathCount += max(1, change.paths.count)
                self.changedPaths.formUnion(change.paths)
                self.requiresFullRescan = self.requiresFullRescan || change.requiresFullScan
            }
        }
        changeMonitor = monitor
        changeTrackingAvailable = monitor.isRunning
    }

    private func incrementalScan() {
        guard let existingTree = tree else { scan(); return }
        endStatistics(outcome: "cancelled")
        task?.cancel()
        changeMonitor?.stop()
        changeMonitor = nil
        changeTrackingAvailable = false
        generation = UUID()
        let thisGeneration = generation
        let scanStartedAt = Date()
        let recorder = ScanStatisticsRecorder(targetID: id, roots: roots.map(\.url.path), mode: "incremental")
        statisticsRecorder = recorder
        let startingEventID = UInt64(FSEventsGetCurrentEventId())
        let paths = Array(changedPaths)
        state = .scanning
        progress = ScanProgress(currentPath: paths.first ?? url.path, itemCount: 0, bytesFound: 0, unreadableCount: 0)

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await DiskScanner.refresh(
                    root: existingTree,
                    changedPaths: paths,
                    scanRoots: roots,
                    statistics: recorder
                ) { [weak self] update in
                    await MainActor.run {
                        guard let self, self.generation == thisGeneration else { return }
                        self.progress = update
                    }
                }
                guard !Task.isCancelled, generation == thisGeneration else { return }
                finishScan(result, startedAt: scanStartedAt, eventID: startingEventID)
            } catch is CancellationError {
                guard generation == thisGeneration else { return }
                endStatistics(outcome: "cancelled")
                state = .complete
                task = nil
            } catch {
                guard generation == thisGeneration else { return }
                endStatistics(outcome: "failed", error: error.localizedDescription)
                state = .failed(error.localizedDescription)
                task = nil
            }
        }
    }

    private func endStatistics(outcome: String, result: ScanTree? = nil, error: String? = nil) {
        guard let recorder = statisticsRecorder else { return }
        statisticsRecorder = nil
        guard let record = recorder.finish(outcome: outcome, progress: progress, tree: result, error: error) else { return }
        scanStatistics = record
        statisticsSaveError = nil
        if persistResults {
            Task {
                do { try await ScanStatisticsStore.shared.save(record) }
                catch { statisticsSaveError = error.localizedDescription }
            }
        }
    }

    private func finishScan(_ result: ScanTree, startedAt: Date, eventID: UInt64) {
        tree = result
        currentID = result.rootID
        selectedID = nil
        let root = result.metadata(for: result.rootID)
        scannedAt = Date()
        scanDuration = Date().timeIntervalSince(startedAt)
        progress = ScanProgress(
            currentPath: name,
            itemCount: root.fileCount + root.directoryCount,
            bytesFound: root.allocatedBytes,
            unreadableCount: progress.unreadableCount,
            duplicateReferenceCount: root.duplicateReferenceCount
        )
        hasFilesystemChanges = false
        changedPathCount = 0
        changedPaths.removeAll()
        requiresFullRescan = false
        endStatistics(outcome: "complete", result: result)
        state = .complete
        task = nil
        startChangeTracking(since: eventID)
        let snapshot = ScanSnapshot(
            version: ScanSnapshot.currentVersion,
            targetID: id,
            tree: result,
            progress: progress,
            scannedAt: scannedAt ?? Date(),
            scanDuration: scanDuration ?? 0,
            fseventID: eventID,
            statistics: scanStatistics
        )
        if persistResults { Task { await SnapshotStore.save(snapshot) } }
    }
}

@MainActor
@Observable
final class AppModel {
    var targets: [ScanTarget] = []
    var viewingTargetID: String?
    var showAuxiliaryMounts = false
    var showTimeMachineMounts = false
    var showDiskImageMounts = false

    init() {
        refreshMountedItems()
        restoreSavedFolders()
    }

    var viewingTarget: ScanTarget? {
        guard let viewingTargetID else { return nil }
        return targets.first { $0.id == viewingTargetID }
    }

    var scanningCount: Int { targets.count { $0.state == .scanning } }
    var visibleTargets: [ScanTarget] {
        targets.filter { target in
            if target.isAuxiliary { return showAuxiliaryMounts }
            if target.isTimeMachine { return showTimeMachineMounts }
            if target.isDiskImage { return showDiskImageMounts }
            return true
        }
    }
    var hiddenAuxiliaryCount: Int { targets.count { $0.isAuxiliary } }
    var auxiliaryTargetCount: Int { targets.count { $0.isAuxiliary } }
    var timeMachineTargetCount: Int { targets.count { !$0.isAuxiliary && $0.isTimeMachine } }
    var diskImageTargetCount: Int { targets.count { !$0.isAuxiliary && !$0.isTimeMachine && $0.isDiskImage } }

    func refreshMountedItems() {
        for target in targets where target.isVolume { target.isAvailable = false }

        let grouped = Dictionary(grouping: MountDiscovery.mountedFilesystems()) { mount in
            mount.apfsContainerUUID.map { "apfs:\($0)" } ?? "mount:\(mount.url.path)"
        }

        for (id, mounts) in grouped {
            let ordered = mounts.sorted {
                if $0.url.path == "/" { return true }
                if $1.url.path == "/" { return false }
                return $0.url.path.count < $1.url.path.count
            }
            guard let primary = ordered.first else { continue }
            let isAPFSContainer = primary.apfsContainerUUID != nil
            let name: String
            if isAPFSContainer, primary.url.path == "/" {
                name = "\(primary.name) APFS Container"
            } else if isAPFSContainer, ordered.count > 1 {
                name = "\(primary.name) APFS Container"
            } else {
                name = primary.name
            }
            let kind: ScanTarget.Kind = isAPFSContainer
                ? .apfsContainer(
                    volumeCount: ordered.count,
                    isInternal: primary.isInternal,
                    isRemovable: primary.isRemovable,
                    isReadOnly: ordered.allSatisfy(\.isReadOnly)
                )
                : .volume(
                    format: primary.format,
                    isInternal: primary.isInternal,
                    isRemovable: primary.isRemovable,
                    isReadOnly: primary.isReadOnly
                )
            let roots = ordered.map { ScanRoot(url: $0.url, name: $0.name) }
            let isAux = !ordered.isEmpty && ordered.allSatisfy(\.isAuxiliary)
            let isTM = !ordered.isEmpty && ordered.contains(where: \.isTimeMachine) && ordered.allSatisfy { $0.isTimeMachine || $0.isAuxiliary }
            let isDI = !ordered.isEmpty && ordered.allSatisfy(\.isDiskImage)

            if let existing = targets.first(where: { $0.id == id }) {
                existing.name = name
                existing.kind = kind
                existing.url = primary.url
                existing.roots = roots
                existing.totalCapacity = primary.totalCapacity
                existing.availableCapacity = primary.availableCapacity
                existing.isAvailable = true
                existing.isDiskImage = isDI
                existing.isTimeMachine = isTM
                existing.isAuxiliary = isAux
            } else {
                let target = ScanTarget(
                    id: id,
                    url: primary.url,
                    name: name,
                    kind: kind,
                    roots: roots,
                    totalCapacity: primary.totalCapacity,
                    availableCapacity: primary.availableCapacity,
                    isDiskImage: isDI,
                    isTimeMachine: isTM,
                    isAuxiliary: isAux
                )
                targets.append(target)
                target.restoreSnapshot()
            }
        }
        sortTargets()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a folder to SpaceTree"
        panel.prompt = "Add and Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        addFolderAndScan(selectedURL)
    }

    func scanHome() {
        addFolderAndScan(FileManager.default.homeDirectoryForCurrentUser)
    }

    func addFolderAndScan(_ url: URL) {
        let standardized = url.standardizedFileURL
        let id = "folder:\(standardized.path)"
        let target: ScanTarget
        if let existing = targets.first(where: { $0.id == id }) {
            target = existing
            target.isAvailable = true
        } else {
            target = ScanTarget(
                id: id,
                url: standardized,
                name: standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent,
                kind: .folder
            )
            targets.append(target)
            saveFolderTargets()
            sortTargets()
        }
        target.scan()
    }

    func scanAll() {
        for target in visibleTargets where target.isAvailable { target.scan() }
    }

    func cancelAll() {
        for target in targets { target.cancel() }
    }

    func show(_ target: ScanTarget) {
        guard target.root != nil else { return }
        viewingTargetID = target.id
    }

    func showDashboard() {
        viewingTargetID = nil
    }

    private func sortTargets() {
        targets.sort { lhs, rhs in
            if lhs.isVolume != rhs.isVolume { return lhs.isVolume && !rhs.isVolume }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func restoreSavedFolders() {
        for path in UserDefaults.standard.stringArray(forKey: "SpaceTree.folderTargets") ?? [] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let id = "folder:\(url.path)"
            guard !targets.contains(where: { $0.id == id }) else { continue }
            let target = ScanTarget(
                id: id,
                url: url,
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                kind: .folder,
                isAvailable: FileManager.default.fileExists(atPath: url.path)
            )
            targets.append(target)
            target.restoreSnapshot()
        }
        sortTargets()
    }

    private func saveFolderTargets() {
        let paths = targets.filter { !$0.isVolume }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: "SpaceTree.folderTargets")
    }
}
