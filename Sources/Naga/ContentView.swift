import SwiftUI
import NagaCore
import UniformTypeIdentifiers

// Use the public property-wrapper type explicitly: the macOS 27 CLI SDK also
// exports a same-named macro whose plugin is only bundled with full Xcode.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissionSetup: PermissionSetup
    @ViewState private var restoreTarget: String?

    init(model: AppModel) {
        self.model = model
        self.permissionSetup = model.permissionSetup
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Label("Button Assignments", systemImage: "cursorarrow.click.2").tag("buttons")
                Label("DPI Stages", systemImage: "speedometer").tag("dpi")
            }
            .navigationTitle(AppIdentity.name)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "computermouse").font(.system(size: 26, weight: .light))
                    Text("Naga V2 HyperSpeed").font(.subheadline.weight(.medium))
                    Label(model.connected ? "2.4 GHz connected" : "Waiting for connection", systemImage: model.connected ? "circle.fill" : "circle.dotted")
                        .font(.caption).foregroundStyle(model.connected ? .green : .secondary)
                    if let issue = model.launchAtLoginIssue {
                        Text("Login registration failed").font(.caption).foregroundStyle(.secondary).help(issue)
                    }
                    if model.needsInputAccess || !permissionSetup.accessibilityGranted || model.launchAtLoginIssue != nil || model.launchAtLoginRequiresApproval {
                        Button("Complete Permissions") { model.completePermissionSetup() }
                            .buttonStyle(.link).font(.caption)
                            .disabled(model.renewingPermission || model.busy || model.switchingDPI)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            Group {
                if model.connected {
                    VStack(spacing: 0) {
                        if let notice = model.notice {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: model.needsRecovery ? "arrow.uturn.backward.circle" : "checkmark.circle")
                                Text(notice).font(.callout)
                                Spacer()
                                if model.needsRecovery { Button("Restore") { restoreTarget = "recovery" } }
                            }.padding(14).background(.quaternary.opacity(0.4))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            profileSelector.padding(.horizontal, 32).padding(.vertical, 14)
                            Divider()
                            ScrollView {
                                if model.selectedSection == "dpi" { dpiPage }
                                else { buttonsPage }
                            }
                        }
                        .disabled(!model.canEdit)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { applyBar }
                } else { waitingPage }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if model.preview { ToolbarItem { Text("Preview").foregroundStyle(.secondary) } }
                if !model.needsInputAccess {
                    ToolbarItem {
                        Button { model.refresh(silent: false) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(model.busy || model.checking || model.switchingDPI || model.recording).help("Read the mouse settings again")
                    }
                }
                ToolbarItem {
                    Menu {
                        Button("Load Assignments from Mac") { model.loadMacCopy() }
                        Divider()
                        Button("Restore Settings Before Last Change…") { restoreTarget = "previous" }
                        Button("Restore Settings from First Connection…") { restoreTarget = "initial" }
                        Divider()
                        Button("Show Backup Folder") { NSWorkspace.shared.open(model.stateDirectory) }
                    } label: { Label("Restore", systemImage: "clock.arrow.circlepath") }
                    .disabled(!model.connected || model.busy || model.switchingDPI || model.preview || model.recording)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(.accentColor)
        .task {
            await Task.yield()
            model.beginPermissionSetup()
        }
        .onChange(of: model.selectedSection) { _, _ in model.recording = false }
        .alert("Operation Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Restore the backup settings to the mouse?", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
            Button("Restore") {
                let target = restoreTarget; restoreTarget = nil
                model.restore(initial: target == "initial", recovery: target == "recovery")
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: { Text("This mouse's button and DPI settings will be restored to the selected backup.") }
    }

    private var navigationTitle: String {
        switch model.selectedSection {
        case "dpi": return "DPI Stages"
        default: return "Button Assignments"
        }
    }

    private var buttonsPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(applicationProfileDescription).font(.callout).foregroundStyle(.secondary)
            buttonAssignments
        }.padding(32).frame(maxWidth: 920, alignment: .leading)
    }

    private var profileSelector: some View {
        HStack(spacing: 12) {
            Picker("Profile", selection: $model.selectedApplicationTarget) {
                Text(AppModel.defaultApplicationName).tag(nil as ApplicationProfile.Target?)
                ForEach(model.applicationProfiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }.fixedSize()
            Menu {
                Button("macOS Application (.app)…") { chooseApplication(wine: false) }
                Button("Wine Application (.exe)…") { chooseApplication(wine: true) }
            } label: { Label("Add Profile", systemImage: "plus") }
            .fixedSize()
            if model.selectedApplicationTarget == .unlinkedWineExecutable {
                Button("Link .exe to This Profile…") { chooseApplication(wine: true, linkExisting: true) }
            }
            Spacer()
            if model.selectedApplication != nil {
                Button(role: .destructive) { model.removeSelectedApplicationProfile() } label: {
                    Label("Remove Profile", systemImage: "trash")
                }
            }
        }
    }

    private var applicationProfileDescription: String {
        if model.selectedApplicationTarget == .unlinkedWineExecutable {
            return "Link a Wine .exe file to enable this profile's assignments."
        }
        return model.editingApplication
            ? "Custom button assignments become active when this app is in the foreground. Other buttons use their default assignments."
            : "These button settings are used when no per-app assignment exists."
    }

    private func chooseApplication(wine: Bool, linkExisting: Bool = false) {
        let panel = NSOpenPanel()
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        panel.directoryURL = wine && FileManager.default.fileExists(atPath: userApplications.path) ? userApplications : systemApplications
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = wine
        panel.allowedContentTypes = wine ? [UTType(filenameExtension: "exe") ?? .data] : [.applicationBundle]
        panel.prompt = "Add Profile"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if wine {
                guard url.pathExtension.lowercased() == "exe",
                      (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    model.error = "Select a Windows .exe file."
                    return
                }
                let target = ApplicationProfile.Target.wineExecutable(url.lastPathComponent.lowercased())
                if linkExisting { model.linkWineProfile(to: target) }
                else { model.addApplicationProfile(target: target, name: url.deletingPathExtension().lastPathComponent + " (Wine)") }
                return
            }
            guard url.pathExtension.lowercased() == "app", let identifier = Bundle(url: url)?.bundleIdentifier else {
                model.error = "The selected application's identifier could not be read."
                return
            }
            let name = FileManager.default.displayName(atPath: url.path)
            model.addApplicationProfile(target: .bundleIdentifier(identifier), name: name)
        }
    }

    private var buttonAssignments: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                Text("SIDE BUTTONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(MouseControl.all.filter { $0.number != nil }) { control in controlButton(control) }
                }
                Text("WHEEL TILT").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10)
                HStack(spacing: 10) {
                    ForEach(MouseControl.all.filter { $0.number == nil }) { control in controlButton(control) }
                }
            }.frame(maxWidth: .infinity)
            editor.frame(width: 260)
        }
    }

    private func controlButton(_ control: MouseControl) -> some View {
        let action = model.action(for: control.id)
        let selected = model.selectedControl == control.id
        let changed = model.hasUnappliedChange(control.id)
        let showsMacIcon = model.actionNeedsMac(control.id)
        return Button {
            model.recording = false; model.selectedControl = control.id
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let number = control.number { Text(String(number)).font(.system(size: 17, weight: .semibold, design: .rounded)) }
                    else { Image(systemName: control.id == 0x34 ? "arrow.left" : "arrow.right").font(.system(size: 17, weight: .semibold)) }
                    Spacer(minLength: 0)
                    if changed { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange) }
                    if showsMacIcon { Image(systemName: "desktopcomputer").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(action.label).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(13).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(changed ? Color.orange.opacity(selected ? 0.18 : 0.10) : selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : changed ? .orange.opacity(0.7) : .primary.opacity(0.07), lineWidth: selected || changed ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).accessibilityLabel("\(control.title), \(action.label)\(changed ? ", unapplied change" : "")")
        .help(changed ? "Unapplied change" : control.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var editor: some View {
        let appOverride = model.editingApplication && !model.inheritsSelectedAction
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedTitle).font(.title2.weight(.semibold))
                if model.editingApplication {
                    Label(appOverride ? "Custom for This App" : "Default Assignment", systemImage: appOverride ? "desktopcomputer" : "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(model.actionNeedsMac(model.selectedControl) ? "Runs on Mac" : "Stored on Mouse", systemImage: model.actionNeedsMac(model.selectedControl) ? "desktopcomputer" : "computermouse")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Assignment").font(.subheadline.weight(.medium))
                Menu {
                    Button("Record Keyboard Shortcut…") { model.recording = true }
                    Section("Mouse Buttons") {
                        ForEach(MouseButtonAction.allCases, id: \.rawValue) { button in
                            Button(button.title) {
                                model.recording = false
                                model.setAction(.mouseButton(button))
                            }
                        }
                    }
                } label: {
                    Text(model.selectedAction.label).frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderedButton)
                .accessibilityLabel("Choose assignment: \(model.selectedAction.label)")
                if case .mouseButton(let button) = model.selectedAction, !model.recording, !model.editingApplication {
                    Text("Sends mouse button \(button.rawValue). Its behavior depends on the application's support.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ShortcutRecorder(recording: $model.recording, shortcut: {
                        if case .shortcut(let s) = model.selectedAction { return s }; return nil
                    }(), onCapture: { model.setAction(.shortcut($0)) }).frame(height: 72)
                    Text(model.recording ? "Press Esc to cancel." : "Click the field, then press your shortcut.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.canRecordSystemShortcuts {
                        Text("Accessibility access is required to record system shortcuts such as Control + Arrow.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(model.editingApplication && !model.canOverrideSelectedAction)
            if appOverride || model.actionNeedsMac(model.selectedControl) {
                Text("Naga must keep running in the background for this assignment.").font(.callout).foregroundStyle(.secondary)
            }
            if case .original = model.selectedAction {
                Text(model.editingApplication
                     ? "First choose a default assignment for this button under Button Assignments."
                     : "This assignment cannot be read as a keyboard shortcut. It stays on the mouse until you choose a new shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button("Undo Change") { model.revertSelectedAction() }
                    .disabled(!model.hasUnappliedChange(model.selectedControl))
                    .help("Discard this button's unapplied change")
                if model.editingApplication {
                    Button("Use Default Assignment") { model.recording = false; model.setApplicationAction(nil) }
                        .disabled(!appOverride)
                }
                Button("Disable Button") { model.recording = false; model.setAction(.disabled) }
                    .disabled(model.editingApplication && !model.canOverrideSelectedAction)
            }.buttonStyle(.link)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }
    private var dpiPage: some View {
        let hasCustomDPI = model.selectedApplication?.dpi != nil
        return VStack(alignment: .leading, spacing: 22) {
            if model.editingApplication {
                Toggle("Custom DPI Stages for This Profile", isOn: Binding(get: { hasCustomDPI }, set: model.useApplicationDPI))
                Text(hasCustomDPI
                     ? "This table is written to the mouse's memory when needed as the app enters the foreground."
                     : "This profile uses the default DPI stages.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            dpiEditor.disabled(model.editingApplication && !hasCustomDPI)
                .id(model.selectedApplicationTarget)
        }.padding(32).frame(maxWidth: 780, alignment: .leading)
    }

    private var dpiEditor: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(spacing: 0) {
                ForEach(Array((model.selectedDPI?.stages ?? []).enumerated()), id: \.offset) { index, stage in
                    if index > 0 { Divider().padding(.leading, 64) }
                    HStack(spacing: 18) {
                        Button { model.selectStage(index) } label: {
                            Image(systemName: model.selectedDPI?.active == index + 1 ? "largecircle.fill.circle" : "circle")
                                .font(.title2).foregroundStyle(model.selectedDPI?.active == index + 1 ? Color.accentColor : .secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Activate stage \(index + 1)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Stage \(index + 1)").font(.body.weight(.medium))
                            if model.selectedDPI?.active == index + 1 { Text("Initial stage").font(.caption).foregroundStyle(.secondary) }
                            if stage.x != stage.y { Text("Y axis: \(stage.y)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        DPIInput(value: stage.x) { model.setStage(index, value: $0) }.frame(width: 110)
                        Text("DPI").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Button { model.removeStage(index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .disabled((model.selectedDPI?.stages.count ?? 0) <= 1)
                            .accessibilityLabel("Remove stage \(index + 1)")
                    }.padding(20)
                }
            }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
            HStack {
                Button { model.addStage() } label: { Label("Add Stage", systemImage: "plus") }
                    .disabled((model.selectedDPI?.stages.count ?? 0) >= 5)
                Spacer()
                Text("100–30000 DPI · Up to 5 stages").font(.caption).foregroundStyle(.secondary)
            }
            Label("Use the DPI buttons on top of the mouse to switch between the active profile's stages.", systemImage: "computermouse")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private var applyBar: some View {
        HStack(spacing: 14) {
            if model.busy || model.switchingDPI { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.busy ? "Verifying settings…" : model.switchingDPI ? "Switching DPI stages…" : model.dirty ? "Unsaved changes" : "Settings are up to date")
                    .font(.subheadline.weight(.medium))
                if model.macCount > 0 { Text("Assignments requiring the app to stay open: \(model.macCount).").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Apply") { model.apply() }.buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!model.canApply).keyboardShortcut("s", modifiers: .command)
        }.padding(.horizontal, 28).padding(.vertical, 16).background(.bar)
    }
    private var waitingPage: some View {
        VStack(spacing: 22) {
            Image(systemName: model.needsInputAccess ? "hand.raised" : "computermouse")
                .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Text(model.needsInputAccess ? "Mouse Access Permission" : "Connect Your Naga").font(.title2.weight(.semibold))
                Text(model.needsInputAccess
                     ? "Grant access in macOS to connect the mouse.\nThe connection is established automatically once permission is granted."
                     : "Connect the USB receiver and turn on the mouse in 2.4 GHz mode.\nYour settings will appear here once connected.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(4)
            }
            if model.checking || model.renewingPermission { ProgressView().controlSize(.small) }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DPIInput: View {
    let value: Int
    let onChange: (Int) -> Void
    @ViewState private var text: String
    init(value: Int, onChange: @escaping (Int) -> Void) { self.value = value; self.onChange = onChange; _text = ViewState(initialValue: String(value)) }
    var body: some View {
        TextField("DPI", text: $text).textFieldStyle(.roundedBorder).monospacedDigit()
            .onChange(of: text) { _, next in onChange(Int(next) ?? 0) }
            .onChange(of: value) { _, next in if Int(text) != next, next != 0 { text = String(next) } }
            .accessibilityLabel("DPI value")
            .overlay(alignment: .bottomTrailing) {
                if !(100...30000).contains(value) { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).offset(x: 16) }
            }
    }
}
