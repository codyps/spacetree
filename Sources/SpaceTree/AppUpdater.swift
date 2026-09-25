import Combine
import Foundation
import Sparkle
import SwiftUI

/// Missing configuration deliberately disables all updater activity (including
/// Sparkle's first-run permission prompt) in local/unbundled builds.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: Data

    init?(bundleURL: URL, info: [String: Any]) {
        guard bundleURL.pathExtension == "app",
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else { return nil }
        feedURL = url
        publicKey = bytes
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var startupError: String?
    private var controller: SPUStandardUpdaterController?
    private var started = false

    let isConfigured: Bool

    init(bundle: Bundle = .main) {
        isConfigured = UpdateConfiguration(bundleURL: bundle.bundleURL,
                                            info: bundle.infoDictionary ?? [:]) != nil
    }

    func start() {
        guard isConfigured, !started else { return }
        started = true
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                       updaterDelegate: nil,
                                                       userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        do {
            try updater.start()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Software Updates") {
                if updater.isConfigured {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
                    Toggle("Automatically download and install updates", isOn: Binding(
                        get: { updater.automaticallyDownloads }, set: { updater.setAutomaticallyDownloads($0) }))
                        .disabled(!updater.automaticallyChecks)
                    Text("Updates are downloaded from GitHub. You can also check manually and choose Install and Relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check for Updates…", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    if let error = updater.startupError {
                        Text(error).foregroundStyle(.red)
                    }
                } else {
                    Text("Integrated updates are not enabled in this build.")
                    Link("Download releases on GitHub", destination: URL(string: "https://github.com/codyps/spacetree/releases")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 250)
        .onAppear { updater.start() }
    }
}
