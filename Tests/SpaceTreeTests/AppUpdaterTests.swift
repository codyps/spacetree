import Foundation
import Testing
@testable import SpaceTree

@Test func updaterRequiresPackagedAppAndValidSigningConfiguration() {
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    let info: [String: Any] = ["SUFeedURL": "https://github.com/codyps/spacetree/releases/latest/download/appcast.xml",
                              "SUPublicEDKey": key]
    let app = URL(fileURLWithPath: "/Applications/SpaceTree.app")
    #expect(UpdateConfiguration(bundleURL: app, info: info) != nil)
    #expect(UpdateConfiguration(bundleURL: URL(fileURLWithPath: "/tmp/debug"), info: info) == nil)
    #expect(UpdateConfiguration(bundleURL: app, info: [:]) == nil)
    for invalid in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "nonsense"] {
        var changed = info
        changed["SUFeedURL"] = invalid
        #expect(UpdateConfiguration(bundleURL: app, info: changed) == nil)
    }
    for invalid in ["", "invalid", Data(repeating: 42, count: 31).base64EncodedString()] {
        var changed = info
        changed["SUPublicEDKey"] = invalid
        #expect(UpdateConfiguration(bundleURL: app, info: changed) == nil)
    }
}

@MainActor @Test func unconfiguredUpdaterDoesNotStartOrCheck() {
    let updater = AppUpdater()
    #expect(!updater.isConfigured)
    updater.start()
    updater.start()
    updater.checkForUpdates()
    updater.setAutomaticallyChecks(true)
    updater.setAutomaticallyDownloads(true)
    #expect(!updater.canCheckForUpdates)
    #expect(!updater.automaticallyChecks)
    #expect(!updater.automaticallyDownloads)
    #expect(updater.startupError == nil)
}
