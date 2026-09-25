import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Packaged apps keep resources in Contents/Resources, while SwiftPM's
        // generated accessor otherwise falls back to an absolute build path.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        // SwiftPM launches an unbundled executable, so opt into the menu bar and Dock.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct SpaceTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { updater.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SpaceTree") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    if let version = Bundle.main.object(forInfoDictionaryKey: "SpaceTreeDisplayVersion") as? String {
                        options[.applicationVersion] = version
                    }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandMenu("Go") {
                Button("Back") { model.viewingTarget?.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.viewingTarget?.canGoBack != true)
                Button("Forward") { model.viewingTarget?.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.viewingTarget?.canGoForward != true)
                Button("Enclosing Folder") { model.viewingTarget?.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.viewingTarget?.canGoUp != true)
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Scan Home Folder") { model.scanHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Scan All Mounted Items") { model.scanAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
        Settings {
            UpdateSettingsView(updater: updater)
        }
    }
}
