import SwiftUI

struct ShipyardApp: App {
    @State private var engine = Engine()

    var body: some Scene {
        Window("Shipyard", id: "main") {
            ContentView()
                .environment(engine)
                .frame(minWidth: 720, minHeight: 440)
                .navigationTitle("Shipyard")
        }
        .defaultSize(width: 860, height: 560)
        .windowToolbarStyle(.unified(showsTitle: false))   // the window is still named Shipyard; the toolbar just doesn't spend space on it
        MenuBarExtra {
            MenuContent().environment(engine)
        } label: {
            Image(systemName: engine.busy ? "arrow.triangle.2.circlepath"
                  : engine.hasFailure ? "exclamationmark.triangle" : "sailboat.fill")
        }
        Settings { SettingsView().environment(engine) }
    }
}

struct MenuContent: View {
    @Environment(Engine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.status)
        if engine.paused && !engine.busy {
            Button("Start Automatic Builds") { engine.start() }
        } else {
            Button(engine.busy ? "Stop" : "Stop Automatic Builds") { engine.stop() }
        }
        Button("Build") { engine.buildNow() }.disabled(engine.busy)
        Divider()
        Button("Open Shipyard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Shipyard") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @Environment(Engine.self) private var engine
    @State private var showLog = false
    @State private var choosing = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            if engine.project == nil {
                ContentUnavailableView {
                    Label("No project yet", systemImage: "sailboat")
                } description: {
                    Text("Choose a project folder to start watching it: Flutter, React Native, native iOS or native Android.")
                } actions: {
                    Button("Choose Project…") { choosing = true }.buttonStyle(.borderedProminent)
                }
            } else {
                SummaryHeader(sha: engine.latestSHA, subject: engine.latestSubject, status: engine.status,
                              busy: engine.busy, paused: engine.paused, failed: engine.failed.contains { $0.value == engine.latestSHA }, checked: engine.lastChecked,
                              devices: engine.devices)
                Divider()
                if showHistory {
                    HistoryList()
                } else {
                    DeviceList()
                }
            }
            Divider()
            LogBar(showLog: $showLog, log: engine.log)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { HStack(spacing: 8) { ProjectPickers(choosing: $choosing) } }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $showHistory) {
                    Text("Devices").tag(false)
                    Text("History").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await engine.tick() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for devices and new commits now")
                    .disabled(engine.busy || engine.project == nil)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Project settings")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { engine.addProject(url.path) }
        }
    }
}

/// Project and branch selection. Disabled during a pass so a build can't switch project halfway.
struct ProjectPickers: View {
    @Environment(Engine.self) private var engine
    @Binding var choosing: Bool

    var body: some View {
        let branch = engine.project?.branch ?? ""
        let branches = engine.branches.contains(branch) || branch.isEmpty ? engine.branches : [branch] + engine.branches
        Menu {
            ForEach(engine.projects) { project in
                Toggle(project.name, isOn: Binding(get: { project.path == engine.currentPath },
                                                   set: { _ in engine.select(project.path) }))
            }
            Divider()
            Button("Add Project…") { choosing = true }
        } label: {
            Label(engine.project?.name ?? "Choose Project", systemImage: "folder").labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
        .disabled(engine.busy)
        .help("Project to watch")

        if engine.project != nil {
            BranchPicker(branch: branch, branches: branches)
        }
    }
}

/// Branch button that opens a small searchable list. A project can have hundreds of branches,
/// which a plain menu would stretch across the whole screen.
struct BranchPicker: View {
    @Environment(Engine.self) private var engine
    let branch: String
    let branches: [String]
    @State private var open = false
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [String] {
        // the branch in use first, so it is visible without scrolling
        let ordered = [branch] + branches.filter { $0 != branch }
        return query.isEmpty ? ordered : ordered.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func choose(_ name: String) {
        open = false
        if name != branch { engine.setBranch(name) }
    }

    var body: some View {
        Button { query = ""; open = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(branch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280)
            .fixedSize()
        }
        .help("Branch to build from: \(branch)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search branches", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                    .onSubmit { if let first = matches.first { choose(first) } }
                    .padding(10)
                Divider()
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches, id: \.self) { name in
                                BranchRow(name: name, current: name == branch) { choose(name) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Divider()
                Text(query.isEmpty ? "\(branches.count) branches" : "\(matches.count) of \(branches.count) branches")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            .frame(width: 340, height: 380)
            // A popover opened from the toolbar doesn't take the keyboard by itself, so typing went nowhere
            // until you clicked the field. Make its window key, then focus the search field.
            .background(KeyWindow())
        }
    }
}

/// Gives the window it lands in the keyboard, with the cursor in its first text field.
private struct KeyWindow: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            // once the popover has finished appearing: take the keyboard and put the cursor in its text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let window = self?.window else { return }
                window.makeKey()
                if let field = Self.textField(in: window.contentView) { window.makeFirstResponder(field) }
            }
        }
        private static func textField(in view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

/// One branch in the picker: the whole row is the click target and lights up under the pointer.
struct BranchRow: View {
    let name: String
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.caption.weight(.bold)).opacity(current ? 1 : 0)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// The newest commit, how many devices have it, and what the app is doing right now.
struct SummaryHeader: View {
    @Environment(Engine.self) private var engine
    let sha: String?
    let subject: String
    let status: String
    let busy: Bool
    let paused: Bool
    let failed: Bool
    let checked: Date?
    let devices: [Device]

    var body: some View {
        let onLatest = devices.filter { sha != nil && $0.installedSHA == sha }.count
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest commit").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                if let sha {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sha.prefix(7)).font(.body.monospaced()).foregroundStyle(.secondary)
                        Text(subject).font(.headline).lineLimit(1).truncationMode(.tail)
                    }
                } else {
                    Text("Not checked yet").font(.headline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small)
                        Text(status)
                    } else {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : paused ? "pause.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? AnyShapeStyle(.orange) : paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                        Text(status)
                        if let checked {
                            Text("· checked \(checked, format: .relative(presentation: .named))")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            RunControls(busy: busy, paused: paused, ready: sha != nil)
            if sha != nil, !devices.isEmpty {
                VStack(spacing: 0) {
                    Text("\(onLatest)/\(devices.count)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(onLatest == devices.count ? .green : .primary)
                    Text("on latest").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Start, Stop and Build. Start is the highlighted one while automatic builds are stopped,
/// which is the state a branch change leaves the project in.
struct RunControls: View {
    @Environment(Engine.self) private var engine
    let busy: Bool
    let paused: Bool
    let ready: Bool   // a commit has been read

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if paused && !busy {
                    Button { engine.start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { engine.start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                }
            }
            .disabled(busy || !paused)
            .help("Build and install new commits automatically")

            Button { engine.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!busy && paused)
                .help(busy ? "Stop what is running, and stop automatic builds" : "Stop automatic builds")

            Button { engine.buildNow() } label: { Label("Build", systemImage: "hammer.fill") }
                .disabled(busy || !ready)
                .help("Build the latest commit now, without installing it")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }
}

struct DeviceList: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        let online = engine.devices.filter(\.online)
        let offline = engine.devices.filter { !$0.online }
        if engine.devices.isEmpty {
            ContentUnavailableView("No devices found", systemImage: "iphone.slash",
                                   description: Text("Connect a phone by USB or Wi-Fi, or start a simulator. It appears here within a minute."))
        } else {
            List {
                if !online.isEmpty {
                    Section("Connected") {
                        ForEach(online) { DeviceRow(device: $0, latest: engine.latestSHA, busy: engine.busy, paused: engine.paused,
                                                    supported: engine.project?.command($0.platform).isEmpty == false) }
                    }
                }
                if !offline.isEmpty {
                    Section("Offline") {
                        ForEach(offline) { DeviceRow(device: $0, latest: engine.latestSHA, busy: engine.busy, paused: engine.paused,
                                                    supported: engine.project?.command($0.platform).isEmpty == false) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct HistoryList: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        if engine.history.isEmpty {
            ContentUnavailableView("No builds yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("The last few builds are kept here so you can put an older one back on a device."))
        } else {
            List(engine.history) { record in
                HistoryRow(record: record, isLatest: record.sha == engine.latestSHA,
                           devices: engine.devices.filter { $0.online && record.succeeded($0.platform) },
                           busy: engine.busy)
            }
            .listStyle(.inset)
        }
    }
}

struct LogBar: View {
    @Binding var showLog: Bool
    let log: String

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { showLog.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showLog ? 90 : 0))
                    Label("Build log", systemImage: "terminal")
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showLog {
                LogView(log: log)
                    .frame(height: 190)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background(.bar)
    }
}

struct DeviceRow: View {
    @Environment(Engine.self) private var engine
    let device: Device
    let latest: String?
    let busy: Bool
    let paused: Bool      // automatic builds are stopped, so nothing will install by itself
    let supported: Bool   // false when the project has no build command for this device's platform

    private var isLatest: Bool { latest != nil && device.installedSHA == latest }
    private var isLocked: Bool { device.error?.hasPrefix("Locked") == true }

    /// A sentence only when the badge alone doesn't say enough.
    private var note: String? {
        if !supported { return "This project has no \(device.platform.label) build command. Add one in Settings." }
        if let error = device.error { return error }
        guard let latest, device.installedSHA != latest, device.auto, !device.installing, !paused else { return nil }
        return device.online ? "Will install \(latest.prefix(7)) on the next check" : "Will get \(latest.prefix(7)) when it reconnects"
    }

    /// The at-a-glance answer to "does this device have the newest build?"
    private var badge: (text: String, icon: String, color: Color) {
        if !supported { return ("No build", "minus.circle", .secondary) }
        if device.installing { return ("Installing", "arrow.down.circle.fill", .blue) }
        if device.error != nil {
            return isLocked ? ("Locked", "lock.fill", .orange) : ("Failed", "exclamationmark.triangle.fill", .red)
        }
        guard device.installedSHA != nil else { return ("Not installed", "circle.dashed", .secondary) }
        if isLatest { return ("Latest", "checkmark.seal.fill", .green) }
        return latest == nil ? ("Installed", "checkmark.circle.fill", .secondary) : ("Update available", "arrow.up.circle.fill", .orange)
    }

    private var deviceIcon: String {
        if device.connection == .simulator && device.platform == .iosSim { return "macbook.and.iphone" }
        if device.platform == .android { return "smartphone" }
        return device.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }

    private var connectionIcon: String {
        switch device.connection {
        case .wired: "cable.connector"
        case .wireless: "wifi"
        case .simulator: "macwindow"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(device.platform.label)
                    Text("·")
                    if device.online {
                        Label(device.connection.rawValue, systemImage: connectionIcon)
                    } else {
                        Text("Offline")
                    }
                    if let installed = device.installedSHA {
                        Text("·")
                        Text(installed.prefix(7)).monospaced()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(device.error == nil ? AnyShapeStyle(.secondary) : isLocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.red))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if device.installing { ProgressView().controlSize(.small) }
            Label(badge.text, systemImage: badge.icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(badge.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.color.opacity(0.15), in: Capsule())
                .fixedSize()
            Toggle("Auto", isOn: Binding(get: { device.auto }, set: { engine.setAuto(device.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .help("Install every new build on this device automatically")
            // The primary action is prominent only when there is something new to install.
            Group {
                if isLatest {
                    Button("Reinstall") { engine.installNow(device.id) }.buttonStyle(.bordered)
                } else {
                    Button("Install") { engine.installNow(device.id) }.buttonStyle(.borderedProminent)
                }
            }
            .frame(width: 84, alignment: .trailing)
                .disabled(busy || !device.online || !supported)
                .help(device.online ? "Install the latest build on this device now" : "This device is not connected")
        }
        .padding(.vertical, 5)
        .opacity(device.online ? 1 : 0.55)
        // by default the line starts wherever the row's first text happens to be, so rows disagree
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        .contextMenu {
            Button("Forget This Device", role: .destructive) { engine.forget(device.id) }
        }
    }
}

struct HistoryRow: View {
    @Environment(Engine.self) private var engine
    let record: BuildRecord
    let isLatest: Bool
    let devices: [Device]   // connected devices this build can go on
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.sha.prefix(7)).monospaced().foregroundStyle(.secondary)
                    Text(record.subject.isEmpty ? "(no message)" : record.subject).lineLimit(1)
                    if isLatest { Text("Latest").font(.caption).foregroundStyle(.green) }
                    if record.uploaded?.values.contains(true) == true {
                        Label("On Firebase", systemImage: "icloud.and.arrow.up").font(.caption).foregroundStyle(.blue)
                    }
                }
                HStack(spacing: 10) {
                    Text("\(record.branch) · \(record.date, format: .relative(presentation: .named))")
                    ForEach(Platform.allCases, id: \.self) { p in
                        if let ok = record.results[p.rawValue] {
                            Label(p.label, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Install") {
                Button("All Connected Devices") { engine.installBuild(record.sha, on: devices.map(\.id)) }
                Divider()
                ForEach(devices) { device in
                    Button(device.name) { engine.installBuild(record.sha, on: [device.id]) }
                }
                if engine.firebaseConfigured {
                    Divider()
                    Button("Upload to Firebase") { engine.uploadBuild(record.sha) }
                }
            }
            .fixedSize()
            .disabled(busy || (devices.isEmpty && !engine.firebaseConfigured))
            .help(isLatest ? "Install this build" : "Install this older build. Auto is turned off for the device so it stays on it.")
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}

struct LogView: View {
    let log: String

    var body: some View {
        ScrollView {
            Text(log.isEmpty ? "Nothing yet." : log)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// Settings for the project currently selected in the main window.
struct SettingsView: View {
    @Environment(Engine.self) private var engine
    @AppStorage("interval") private var interval = 60
    @State private var pendingKind: ProjectKind?   // type picked but not yet confirmed
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            if let project = engine.project {
                let binding = Binding(get: { engine.project ?? project }, set: { engine.update($0) })
                Section {
                    LabeledContent("Folder") {
                        Text(project.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    }
                    TextField("Extra files to copy", text: binding.copy, prompt: Text("assets/fonts config/local.json"))
                    TextField("Apple team ID", text: binding.team, prompt: Text("ABCDE12345"))
                } header: {
                    Text(project.name)
                } footer: {
                    Text("Extra files are git-ignored files the build needs, separated by spaces. They are copied from the project folder. The team ID is only needed when the Xcode project has no team set.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Project type", selection: Binding(get: { project.kind ?? .flutter }, set: { pendingKind = $0 })) {
                        ForEach(ProjectKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(engine.busy)
                    TextField("Before building", text: binding.prepare.orEmpty, prompt: Text("npm install"), axis: .vertical)
                    ForEach(Platform.allCases, id: \.self) { p in
                        TextField("\(p.label) build", text: command(binding, \.commands, p), prompt: Text("not built"), axis: .vertical)
                        TextField("\(p.label) output", text: command(binding, \.artifacts, p), prompt: Text("path to the built .\(p == .android ? "apk" : "app")"))
                    }
                    .font(.callout.monospaced())
                } header: {
                    Text("Build commands")
                } footer: {
                    Text("Commands run in a clean copy of the commit. Choosing a project type fills in the usual commands and replaces any edits. Leave a platform's build empty to skip it. An output path may use * for a name you don't know. $SHIPYARD_TEAM holds the Apple team ID.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Android app ID", text: binding.firebaseAndroid.orEmpty, prompt: Text("1:1234567890:android:abc123"))
                    TextField("iOS app ID", text: binding.firebaseIOS.orEmpty, prompt: Text("1:1234567890:ios:abc123"))
                    TextField("Tester groups", text: binding.firebaseGroups.orEmpty, prompt: Text("qa-team, friends"))
                } header: {
                    Text("Remote testers")
                } footer: {
                    Text("For devices that are not on this network. With an app ID filled in, every new build is uploaded to Firebase App Distribution and the tester groups are notified. Needs the firebase command installed and signed in. Leave empty to turn it off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Remove \(project.name) from Shipyard", role: .destructive) { confirmingRemoval = true }
                        .disabled(engine.busy)
                }
            } else {
                Text("Choose a project in the main window first.").foregroundStyle(.secondary)
            }
            Section("All projects") {
                Stepper("Check every \(interval) seconds", value: $interval, in: 15...600, step: 15)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 620)
        .confirmationDialog("Replace the build commands?", isPresented: Binding(get: { pendingKind != nil }, set: { if !$0 { pendingKind = nil } }),
                            presenting: pendingKind) { kind in
            Button("Use \(kind.label) Commands", role: .destructive) { engine.setKind(kind) }
        } message: { kind in
            Text("The before-building step and every build command and output path are replaced with the usual ones for \(kind.label). Your edits to them are lost.")
        }
        .confirmationDialog("Remove \(engine.project?.name ?? "this project") from Shipyard?", isPresented: $confirmingRemoval) {
            Button("Remove and Delete Kept Builds", role: .destructive) { engine.removeCurrentProject() }
        } message: {
            Text("Shipyard's build copy, kept builds and device list for this project are deleted. Your project folder is not touched.")
        }
    }
}

/// A text binding to one platform's entry in a project's command or output table.
@MainActor private func command(_ project: Binding<Project>, _ table: WritableKeyPath<Project, [String: String]?>, _ p: Platform) -> Binding<String> {
    Binding(get: { project.wrappedValue[keyPath: table]?[p.rawValue] ?? "" },
            set: { project.wrappedValue[keyPath: table] = (project.wrappedValue[keyPath: table] ?? [:]).merging([p.rawValue: $0]) { $1 } })
}

private extension Binding where Value == String? {
    /// Lets a text field edit an optional string, storing "" as-is.
    var orEmpty: Binding<String> { Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0 }) }
}
