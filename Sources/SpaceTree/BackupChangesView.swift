import AppKit
import SwiftUI

@MainActor @Observable
final class BackupChangesModel {
    var snapshots: [BackupSnapshot] = []
    var destinations: [BackupDestination] = []
    var device = ""
    var first = ""
    var last = ""
    var comparisons: [BackupComparison] = [] { didSet { comparisonRevision += 1; updateRankings() } }
    private(set) var comparisonRevision = 0
    var intervalProgress: BackupCommand.Progress?
    var errors: [String] = []
    var status = "Choose a mounted backup destination and a range."
    var running = false
    var completed = 0
    var requested = 0
    var metric: BackupMetric = .sizeDelta { didSet { updateRankings() } }
    var folder = "" { didSet { updateRankings() } }
    var search = "" { didSet { updateRankings() } }
    var selected: String?
    private var task: Task<Void, Never>?
    private var command: BackupCommand?

    var available: [BackupSnapshot] { snapshots.filter { $0.device == device } }
    var devices: [String] { destinations.map(\.id) }
    var canAnalyze: Bool { !running && !first.isEmpty && first < last }
    private(set) var rankings: [BackupRanking] = []
    private func updateRankings() { rankings = BackupAnalysis.rankings(comparisons, metric: metric, folder: folder, search: search) }
    var warnings: [String] { errors + comparisons.flatMap { comparison in comparison.warnings.map { comparison.id + ": " + $0 } } }

    func refresh() {
        guard !running else { return }
        running = true
        status = "Discovering mounted backup snapshots…"
        task = Task {
            let (mounts, images) = await Task.detached {
                (MountDiscovery.mountedFilesystems(), BackupDestinationDiscovery.mountedImagePaths())
            }.value
            guard !Task.isCancelled else { running = false; return }
            snapshots = BackupAnalysis.snapshots(mounts: mounts)
            destinations = BackupDestinationDiscovery.destinations(snapshots: snapshots, mounts: mounts, imagePaths: images)
            if !devices.contains(device) { device = devices.first ?? "" }
            resetRange()
            running = false
            status = "\(available.count) mounted snapshots available."
        }
    }

    func resetRange() {
        first = available.dropLast().suffix(3).first?.id ?? ""
        last = available.last?.id ?? ""
        comparisons = []
        errors = []
        selected = nil
        folder = ""
        completed = 0
        requested = 0
    }

    func analyze() {
        guard canAnalyze else { return }
        let range = available.filter { $0.id >= first && $0.id <= last }
        guard range.count >= 2 else { return }
        comparisons = []
        errors = []
        folder = ""
        selected = nil
        completed = 0
        requested = range.count - 1
        running = true
        task = Task {
            for (older, newer) in zip(range, range.dropFirst()) {
                if Task.isCancelled { break }
                status = "Interval \(completed + 1) of \(requested): \(older.id) → \(newer.id)"
                intervalProgress = nil
                let runner = BackupCommand()
                command = runner
                do {
                    let (updates, continuation) = AsyncStream<BackupCommand.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let worker = Task.detached(priority: .utility) {
                        defer { continuation.finish() }
                        return try runner.run(older: older, newer: newer) { continuation.yield($0) }
                    }
                    let comparison = try await withTaskCancellationHandler {
                        for await update in updates {
                            if Task.isCancelled { break }
                            intervalProgress = update
                        }
                        return try await worker.value
                    } onCancel: { runner.cancel(); worker.cancel() }
                    try Task.checkCancellation()
                    comparisons.append(comparison)
                } catch is CancellationError { break }
                catch { errors.append("\(older.id) → \(newer.id): \(error.localizedDescription)") }
                completed += 1
            }
            command = nil
            intervalProgress = nil
            running = false
            status = Task.isCancelled
                ? "Stopped. \(comparisons.count) completed intervals retained; Analyze reuses cached results."
                : "\(comparisons.count) of \(requested) intervals analyzed. \(errors.count) failed."
        }
    }

    func cancel() { task?.cancel(); command?.cancel() }
}

struct BackupChangesView: View {
    var close: () -> Void
    @State private var model = BackupChangesModel()
    @State private var showCoverage = false

    init(close: @escaping () -> Void, model: BackupChangesModel = BackupChangesModel()) {
        self.close = close
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.cancel(); close() } label: { Label("Disks", systemImage: "chevron.left") }
                Text("Backup Changes").font(.headline)
                Spacer()
                Button("Refresh Snapshots", action: model.refresh).disabled(model.running)
            }
            .padding(12)
            Divider()
            controls.padding(12)
            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Coverage / warnings (\(model.warnings.count))") { showCoverage = true }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if model.running, let progress = model.intervalProgress {
                HStack {
                    Text(progress.label).monospacedDigit()
                    if progress.stage == .classifying, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total)).frame(width: 120)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.snapshots.isEmpty && !model.running {
                ContentUnavailableView("No mounted backup snapshots", systemImage: "clock.badge.exclamationmark", description: Text("Connect your Time Machine disk or mount its network backup. Completed APFS backup snapshots must be mounted before analysis. Local recovery snapshots and legacy HFS+ backups are not included."))
                Text("From a terminal with Full Disk Access, use tmutil listbackups -d <backup-volume> -m, then Refresh Snapshots. SpaceTree may also need Full Disk Access in System Settings → Privacy & Security.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            } else {
                results
            }
        }
        .task { if model.snapshots.isEmpty { model.refresh() } }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showCoverage) {
            VStack {
              ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Analysis coverage").font(.title2)
                    Text("\(model.comparisons.count) successful intervals out of \(model.requested) requested. Comparisons use file sizes and modification times; file contents, ACLs and extended attributes are not compared. A successful command does not guarantee every protected path was accessible.")
                    Text("Only mounted snapshots are compared. Gaps can span multiple backup runs. Subtree summaries are counted once; individual descendants may not be available. Results measure logical changes, not unique APFS blocks or actual network transfer. Renames may appear as a removal and an addition.")
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).textSelection(.enabled) }
                }.padding(24)
              }
              HStack {
                  Button("Full Disk Access Settings") {
                      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                  }
                  Spacer()
                  Button("Done") { showCoverage = false }.keyboardShortcut(.defaultAction)
              }.padding(16)
            }.frame(width: 660, height: 420)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Destination", selection: $model.device) {
                    ForEach(model.destinations) { destination in
                        Label(destination.label, systemImage: destination.symbol).tag(destination.id)
                    }
                }.frame(maxWidth: 360)
                Picker("From", selection: $model.first) {
                    ForEach(model.available) { Text($0.id).tag($0.id) }
                }
                Picker("To", selection: $model.last) {
                    ForEach(model.available) { Text($0.id).tag($0.id) }
                }
            }.disabled(model.running)
            .onChange(of: model.device) { model.resetRange() }
            HStack {
                Text("\(model.available.count) snapshots").font(.caption).foregroundStyle(.secondary)
                if let destination = model.destinations.first(where: { $0.id == model.device }), destination.connection == .network {
                    Label("Network backup · comparisons may be slower", systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(destination.location ?? destination.name)
                }
                Spacer()
                if model.running { Button("Stop", action: model.cancel) }
                Button("Analyze Range", action: model.analyze).disabled(!model.canAnalyze)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var results: some View {
        let rows = model.rankings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Box area", selection: $model.metric) {
                    ForEach(BackupMetric.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 350)
                TextField("Search backup paths", text: $model.search)
                    .textFieldStyle(.roundedBorder)
            }
            Text(model.metric.explanation).font(.caption).foregroundStyle(.secondary)
            if let first = model.comparisons.first, let last = model.comparisons.last {
                Text("Showing analyzed history: \(first.older) → \(last.newer) · \(model.comparisons.count) intervals")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("All folders") { model.folder = ""; model.selected = nil }
                    .disabled(model.folder.isEmpty)
                Button("Up") {
                    model.folder = (model.folder as NSString).deletingLastPathComponent
                    model.selected = nil
                }.disabled(model.folder.isEmpty)
                Text(model.folder.isEmpty ? "All changed paths" : model.folder)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Text(model.comparisons.isEmpty ? "No data" : Self.bytes(rows.reduce(0) { $0 + $1.bytes })).monospacedDigit()
            }
            HSplitView {
                VStack {
                    if model.comparisons.isEmpty && !model.errors.isEmpty {
                        ContentUnavailableView("Analysis failed", systemImage: "exclamationmark.triangle", description: Text("No intervals were analyzed successfully. Open Coverage / warnings for errors and Full Disk Access guidance."))
                    } else if rows.isEmpty {
                        ContentUnavailableView("No changes to display", systemImage: "square.grid.3x3", description: Text(model.comparisons.isEmpty ? "Analyze a range to find recurring changes." : "No positive bytes for this metric and filter. Try Changed file sizes to see same-size rewrites."))
                    } else {
                        BackupChangeMap(comparisons: model.comparisons, revision: model.comparisonRevision,
                                        metric: model.metric, folder: model.folder, search: model.search,
                                        selected: model.selected,
                                        select: { model.selected = $0 },
                                        drill: { model.folder = $0; model.selected = nil })
                    }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Largest contributors").font(.headline)
                    List(rows, selection: $model.selected) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((row.path as NSString).lastPathComponent).lineLimit(1)
                                Text("\(row.intervals.count)/\(model.comparisons.count) intervals\(row.hasSubtree ? " · includes subtree" : "")\(row.unknownType ? " · type unknown" : "")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.bytes(row.bytes)).monospacedDigit()
                            if row.isFolder { Button { drill(row) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless) }
                        }.tag(row.path)
                    }.listStyle(.plain)
                    if let path = model.selected { detail(path) }
                }.frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
            }
        }.padding(12)
    }

    private func drill(_ row: BackupRanking) {
        model.selected = row.path
        if row.isFolder { model.folder = row.path }
    }

    private func detail(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path).font(.caption).textSelection(.enabled)
            Button("Copy Backup-relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Text("Per-interval history · \(model.metric.rawValue)").font(.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.comparisons) { comparison in
                        let changes = comparison.changes.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
                        let amount = changes.reduce(0.0) { $0 + Double(model.metric.bytes($1)) }
                        let delta = changes.reduce(0.0) { $0 + Double($1.delta) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comparison.id).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("\(Self.bytes(amount)) · net \(delta >= 0 ? "+" : "−")\(Self.bytes(abs(delta)))")
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
            }.frame(maxHeight: 150)
            Text("Review the source app’s cache or database settings before excluding a path. Exclusions affect future backups, not retained history.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(8)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024), max(0, value))), countStyle: .file)
    }
}
