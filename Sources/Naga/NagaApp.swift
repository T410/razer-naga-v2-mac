import SwiftUI
import NagaCore
import ServiceManagement

private typealias MenuState<Value> = SwiftUI.State<Value>
private let showMainWindow = Notification.Name("Naga.showMainWindow")

@main
struct NagaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--diagnose") { Diagnostics.run(); exit(0) }
        let preview = CommandLine.arguments.contains("--preview")
        let stateDirectory: URL?
        if let index = CommandLine.arguments.firstIndex(of: "--state-directory"), CommandLine.arguments.indices.contains(index + 1) {
            stateDirectory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        } else { stateDirectory = nil }
        let model = AppModel(preview: preview, directory: stateDirectory)
        _model = StateObject(wrappedValue: model); AppDelegate.model = model
    }
    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 740)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Toggle("Start at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.preview)
            }
        }
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            LaunchMenuLabel()
        }
    }
}

private struct LaunchMenuLabel: View {
    @Environment(\.openWindow) private var openWindow
    @MenuState private var launched = false
    var body: some View {
        Image(systemName: AppIdentity.symbol)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)) { _ in openAtLaunch() }
            .onReceive(NotificationCenter.default.publisher(for: showMainWindow)) { _ in openWindow(id: "main") }
            .onAppear { if NSApp.isRunning { openAtLaunch() } }
    }
    private func openAtLaunch() {
        guard !launched else { return }
        launched = true
        if !AppDelegate.backgroundLaunch { openWindow(id: "main") }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.connected ? "Naga V2 HyperSpeed · connected" : "Waiting for connection")
        if model.canEdit { Text("Active profile · \(model.activeApplicationName ?? AppModel.defaultApplicationName)") }
        if model.connected, let dpi = model.hardware?.dpiX { Text("DPI: \(dpi)") }
        if model.macCount > 0 { Text(model.inputRoutingReady ? "Mac button assignments ready" : "Mac button assignments require Input Monitoring and Accessibility access") }
        Divider()
        Button("Open \(AppIdentity.name)") { NSApp.setActivationPolicy(.regular); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh Mouse Settings") { model.refresh(silent: false) }.disabled(model.busy || model.checking || model.switchingDPI)
        Toggle("Start at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) })).disabled(model.preview)
        Divider()
        Button("Quit \(AppIdentity.name)") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(model.busy || model.switchingDPI)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?
    @MainActor static var backgroundLaunch = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.backgroundLaunch = LoginItem.isBackgroundLaunch(arguments: CommandLine.arguments, event: NSAppleEventManager.shared().currentAppleEvent)
        if Self.backgroundLaunch { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Self.model?.configureLaunchAtLogin() }
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.model?.beginPermissionSetup()
        Self.model?.refresh(silent: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        if model.restartingForPermissions { return .terminateNow }
        if model.busy || model.switchingDPI { return .terminateCancel }
        if model.restoreDefaultDPIOnQuit(completion: { sender.reply(toApplicationShouldTerminate: $0) }) {
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.setActivationPolicy(.regular)
            NotificationCenter.default.post(name: showMainWindow, object: nil)
        }
        return true
    }
}

enum Diagnostics {
    static func run() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("naga-read-only")
        do {
            let io = try HIDMouseIO(directory: directory, mayWrite: false); defer { io.close() }
            let snapshot = try DeviceState.read(from: io)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.indices.contains(index + 1) {
                let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                try encoder.encode(snapshot).write(to: output, options: .atomic)
            }
            print("Read-only diagnostics passed. \(snapshot.bindings.count) bindings, \(try snapshot.dpi.stages.count) DPI stages; current DPI \(snapshot.dpiX)/\(snapshot.dpiY). No settings written.")
        } catch { fputs("Read-only diagnostics: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
