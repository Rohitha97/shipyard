import Foundation
import Observation
import UserNotifications

/// A build target. Each one is built once per commit and has its own artifact.
enum Platform: String, Codable, CaseIterable {
    case ios, android, iosSim

    var label: String {
        switch self {
        case .ios: "iOS"
        case .android: "Android"
        case .iosSim: "iOS Simulator"
        }
    }

}

enum Connection: String {
    case wired = "USB", wireless = "Wi-Fi", simulator = "Simulator"
}

/// What kind of mobile project a folder is. Only used to pick starting build commands; every command stays editable.
enum ProjectKind: String, Codable, CaseIterable {
    case flutter, reactNative, ios, android, custom

    var label: String {
        switch self {
        case .flutter: "Flutter"
        case .reactNative: "React Native"
        case .ios: "iOS (Xcode)"
        case .android: "Android (Gradle)"
        case .custom: "Custom"
        }
    }

    /// Never fails: version 0.2.0 stored the label, and an unknown value must not make the whole project list unreadable.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ProjectKind(rawValue: value) ?? Self.allCases.first { $0.label == value } ?? .custom
    }
}

struct Project: Codable, Identifiable, Equatable {
    var path: String
    var branch = "main"
    var copy = ""          // git-ignored files the build needs, space separated
    var flutterArgs = ""   // only read to upgrade projects saved before build commands were editable
    var team = ""          // Apple team ID, when the Xcode project has none
    // Firebase App Distribution, for devices that are not on this network. Optional so older saved projects still load.
    var firebaseAndroid: String?   // Firebase app ID; empty = don't upload
    var firebaseIOS: String?
    var firebaseGroups: String?    // tester groups, comma separated
    // How to build. nil only in projects saved by older versions, which were all Flutter.
    var kind: ProjectKind?
    var prepare: String?                // runs once per commit before any build (fetch dependencies)
    var commands: [String: String]?     // Platform.rawValue -> build command; empty = platform not built
    var artifacts: [String: String]?    // Platform.rawValue -> built .app/.apk, relative to the project; * allowed
    var dir: String?                    // folder under ~/.shipyard; nil in older projects, which use the folder name
    var paused: Bool?                   // true = watch and report, but build or install only when asked

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    func command(_ p: Platform) -> String { commands?[p.rawValue] ?? "" }
    func artifact(_ p: Platform) -> String { artifacts?[p.rawValue] ?? "" }

    /// Fills prepare/commands/artifacts with the usual ones for `kind`, looking in the folder for names.
    mutating func applyPreset(_ kind: ProjectKind) {
        self.kind = kind
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: path + "/" + rel) }
        func find(in dir: String, ext: String) -> String? {
            ((try? fm.contentsOfDirectory(atPath: dir.isEmpty ? path : path + "/" + dir)) ?? [])
                .filter { $0.hasSuffix("." + ext) && !$0.hasPrefix("Pods") }.sorted().first
        }
        /// xcodebuild for the Xcode project in `dir`. Assumes the scheme is named after the project.
        func xcode(_ dir: String, pods: Bool) -> (ios: String, sim: String, out: String)? {
            guard let proj = find(in: dir, ext: "xcodeproj") else { return nil }
            let scheme = (proj as NSString).deletingPathExtension
            let prefix = dir.isEmpty ? "" : dir + "/"
            let workspace = pods ? scheme + ".xcworkspace" : find(in: dir, ext: "xcworkspace")
            let container = workspace.map { "-workspace \(shq(prefix + $0))" } ?? "-project \(shq(prefix + proj))"
            let base = "xcodebuild \(container) -scheme \(shq(scheme)) -derivedDataPath build/shipyard"
            return ("\(base) -configuration Release -sdk iphoneos -allowProvisioningUpdates ${SHIPYARD_TEAM:+DEVELOPMENT_TEAM=$SHIPYARD_TEAM} build",
                    "\(base) -configuration Release -sdk iphonesimulator build",
                    "build/shipyard/Build/Products")
        }
        switch kind {
        case .flutter:
            prepare = "flutter pub get"
            // release, not debug: iOS debug builds won't launch from the home screen. Simulators can't run release.
            commands = ["ios": "flutter build ios --release", "android": "flutter build apk --release",
                        "iosSim": "flutter build ios --simulator --debug"]
            artifacts = ["ios": "build/ios/iphoneos/Runner.app", "android": "build/app/outputs/flutter-apk/app-release.apk",
                         "iosSim": "build/ios/iphonesimulator/Runner.app"]
        case .reactNative:
            let install = exists("yarn.lock") ? "yarn install" : exists("pnpm-lock.yaml") ? "pnpm install"
                : exists("bun.lockb") || exists("bun.lock") ? "bun install" : "npm install"
            prepare = exists("ios/Podfile") ? "\(install) && (cd ios && pod install)" : install
            // Gradle finds the Android SDK through this git-ignored file, which a clean copy doesn't have
            if copy.isEmpty, exists("android/local.properties") { copy = "android/local.properties" }
            commands = [:]; artifacts = [:]
            if exists("android") {
                commands?["android"] = "cd android && ./gradlew assembleRelease"
                artifacts?["android"] = "android/app/build/outputs/apk/release/*.apk"
            }
            if let x = xcode("ios", pods: exists("ios/Podfile")) {
                commands?["ios"] = x.ios; artifacts?["ios"] = x.out + "/Release-iphoneos/*.app"
                commands?["iosSim"] = x.sim; artifacts?["iosSim"] = x.out + "/Release-iphonesimulator/*.app"
            }
        case .ios:
            prepare = exists("Podfile") ? "pod install" : ""
            commands = [:]; artifacts = [:]
            if let x = xcode("", pods: exists("Podfile")) {
                commands?["ios"] = x.ios; artifacts?["ios"] = x.out + "/Release-iphoneos/*.app"
                commands?["iosSim"] = x.sim; artifacts?["iosSim"] = x.out + "/Release-iphonesimulator/*.app"
            }
        case .android:
            prepare = ""
            if copy.isEmpty, exists("local.properties") { copy = "local.properties" }   // see React Native above
            // debug, because a release APK only installs once the project has a signing config
            commands = ["android": "./gradlew assembleDebug"]
            artifacts = ["android": "app/build/outputs/apk/debug/*.apk"]
        case .custom:
            prepare = ""; commands = [:]; artifacts = [:]
        }
    }

    /// Best guess at what kind of project lives in a folder.
    static func detect(_ path: String) -> ProjectKind {
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: path + "/" + rel) }
        let files = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        if exists("pubspec.yaml") { return .flutter }
        if let pkg = try? String(contentsOfFile: path + "/package.json", encoding: .utf8), pkg.contains("\"react-native\"") { return .reactNative }
        if files.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .ios }
        if ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"].contains(where: exists) { return .android }
        return .custom
    }
}

/// One built commit. Its artifacts are kept on disk so it can be installed again later.
struct BuildRecord: Identifiable, Codable, Equatable {
    var sha: String
    var subject: String
    var branch: String
    var date: Date
    var results: [String: Bool] = [:]   // Platform.rawValue -> build succeeded
    var uploaded: [String: Bool]?       // Platform.rawValue -> uploaded to Firebase

    var id: String { sha }
    func succeeded(_ p: Platform) -> Bool { results[p.rawValue] == true }
}

struct Device: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var platform: Platform
    var auto = true
    var installedSHA: String?
    var error: String?
    var online = false
    var installing = false
    var connection = Connection.wired

    // online/installing/connection are live state, not saved
    enum CodingKeys: String, CodingKey { case id, name, platform, auto, installedSHA, error }

    /// True when this device should get `built` pushed to it without being asked.
    func needsInstall(built: String?) -> Bool {
        online && auto && built != nil && installedSHA != built
    }
}

@MainActor @Observable
final class Engine {
    var projects: [Project] = [] { didSet { persistProjects() } }
    var currentPath = "" { didSet { if !demo { UserDefaults.standard.set(currentPath, forKey: "current") } } }
    var branches: [String] = []

    var devices: [Device] = []
    var history: [BuildRecord] = []        // newest first
    var built: [Platform: String] = [:]    // commit whose artifact is on disk
    var failed: [Platform: String] = [:]   // commit whose build failed (don't loop on it)
    var latestSHA: String?
    var latestSubject = ""
    var lastChecked: Date?
    var status = "Starting…"
    var busy = false {
        didSet {
            guard !busy else { return }
            stopRequested = false
            // A branch picked (or Start pressed) while a pass was running is applied as soon as that pass ends.
            if recheck { recheck = false; Task { self.switchTo(self.project) } }
        }
    }
    private var recheck = false
    private var stopRequested = false      // Stop was pressed during this pass: finish nothing more
    private var running: Canceller?        // the command in flight, so Stop can kill it

    /// Automatic builds are stopped for the current project.
    var paused: Bool { project?.paused == true }
    var log = ""

    var project: Project? { projects.first { $0.path == currentPath } }

    var hasFailure: Bool {
        failed.contains { $0.value == latestSHA } || devices.contains { $0.error != nil && $0.error?.hasPrefix("Locked") != true }
    }

    /// The project a pass is working on. Snapshotted so edits mid-pass can't mix two projects.
    private var active = Project(path: "")
    private var home: String { NSHomeDirectory() + "/.shipyard/" + (active.dir ?? active.name) }
    private var worktree: String { home + "/src" }
    private var stateFile: String { home + "/state.json" }
    private var loadedRepo = ""
    private var events: [String] = []      // what happened this pass, for one notification
    private let keepBuilds = 5             // ponytail: fixed count; each kept build is a few hundred MB
    /// Folder holding the one kept artifact of a build.
    private func archive(_ sha: String, _ p: Platform) -> String { "\(home)/builds/\(sha)/\(p.rawValue)" }
    /// Shell expression for that artifact, whatever the project named it.
    private func kept(_ sha: String, _ p: Platform) -> String { q(archive(sha, p)) + (p == .android ? "/*.apk" : "/*.app") }
    private var interval: Int { max(15, UserDefaults.standard.object(forKey: "interval") as? Int ?? 60) }

    /// `Shipyard --demo` shows sample data and touches nothing: for screenshots and trying the UI.
    private let demo = CommandLine.arguments.contains("--demo")

    init() {
        if demo { loadDemo(); return }
        let d = UserDefaults.standard
        if let data = d.data(forKey: "projects") {
            if let saved = try? JSONDecoder().decode([Project].self, from: data) {
                projects = saved
            } else {
                d.set(data, forKey: "projects.unreadable")   // keep it: the save below would otherwise erase it
            }
        } else if let repo = d.string(forKey: "repo"), !repo.isEmpty {   // settings from the single-project version
            projects = [Project(path: repo, branch: d.string(forKey: "branch") ?? "main",
                                copy: d.string(forKey: "copy") ?? "",
                                flutterArgs: d.string(forKey: "flutterArgs") ?? "",
                                team: d.string(forKey: "team") ?? "")]
        }
        // Projects saved before build commands were editable were all Flutter.
        for i in projects.indices where projects[i].commands == nil {
            let args = projects[i].flutterArgs
            projects[i].applyPreset(.flutter)
            if !args.isEmpty { projects[i].commands = projects[i].commands?.mapValues { $0 + " " + args } }
        }
        currentPath = d.string(forKey: "current") ?? ""
        if project == nil { currentPath = projects.first?.path ?? "" }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        persistProjects()   // didSet doesn't run inside init
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: projects

    private func persistProjects() {
        guard !demo else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: "projects")
    }

    func addProject(_ path: String) {
        if !projects.contains(where: { $0.path == path }) {
            var project = Project(path: path)
            project.applyPreset(Project.detect(path))
            // Two projects can share a folder name (…/a/app, …/b/app); each still needs its own build folder.
            let used = Set(projects.map { $0.dir ?? $0.name })
            var dir = project.name, n = 2
            while used.contains(dir) { dir = "\(project.name)-\(n)"; n += 1 }
            project.dir = dir
            projects.append(project)
        }
        select(path)
    }

    /// Settings' project type picker: replaces the build commands with the usual ones for that type.
    func setKind(_ kind: ProjectKind) {
        guard !busy, let i = projects.firstIndex(where: { $0.path == currentPath }) else { return }
        projects[i].applyPreset(kind)
    }

    /// Removes the project from Shipyard along with its build copy and kept builds. The project folder itself is untouched.
    func removeCurrentProject() {
        guard !busy, let project else { return }
        busy = true
        Task {
            active = project
            let dir = project.dir ?? project.name
            if !dir.isEmpty, !dir.contains("/"), dir != ".", dir != ".." {   // only ever delete inside ~/.shipyard
                let repo = q(project.path)
                _ = await sh("git -C \(repo) worktree remove --force \(q(worktree)); git -C \(repo) worktree prune", quiet: true, timeout: 120)
                try? FileManager.default.removeItem(atPath: home)
            }
            projects.removeAll { $0.path == project.path }
            loadedRepo = ""   // so nothing is saved back into the folder just deleted
            busy = false
            select(projects.first?.path ?? "")
        }
    }

    func select(_ path: String) {
        guard !busy else { return }
        currentPath = path
        switchTo(project)
    }

    /// Always takes effect: the running pass keeps its own snapshot of the project, so this can't disturb it.
    func setBranch(_ branch: String) {
        guard let i = projects.firstIndex(where: { $0.path == currentPath }) else { return }
        projects[i].branch = branch
        projects[i].paused = true   // a new branch is only looked at; building it is the user's call (Start or Build)
        if busy { recheck = true } else { switchTo(project) }
    }

    // MARK: Start / Stop / Build

    /// Start: build and install new commits automatically again.
    func start() {
        guard !demo, let i = projects.firstIndex(where: { $0.path == currentPath }) else { return }
        projects[i].paused = false
        if busy { recheck = true } else { Task { await tick() } }
    }

    /// Stop: kill whatever is running and stop automatic builds until Start is pressed.
    func stop() {
        guard !demo, let i = projects.firstIndex(where: { $0.path == currentPath }) else { return }
        projects[i].paused = true
        if busy {
            stopRequested = true
            running?.cancel()
            status = "Stopping…"
            append("[stopped]\n")
        } else {
            status = "Stopped"
        }
    }

    /// Build: build the latest commit now, without installing it.
    func buildNow() { Task { await tick(.build) } }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.path == project.path }) else { return }
        projects[i] = project
    }

    private func switchTo(_ project: Project?) {
        guard !demo else { return }   // sample data has nothing to reload
        latestSHA = nil; latestSubject = ""
        guard let project else { devices = []; branches = []; loadedRepo = ""; return }
        if loadedRepo != project.path { active = project; branches = []; load() }
        Task { await tick() }
    }

    // MARK: remote delivery

    private func firebaseApp(_ p: Platform, in project: Project? = nil) -> String? {
        let project = project ?? active
        let id = p == .android ? project.firebaseAndroid : p == .ios ? project.firebaseIOS : nil
        return id?.isEmpty == false ? id : nil
    }

    var firebaseConfigured: Bool {
        project.map { firebaseApp(.android, in: $0) != nil || firebaseApp(.ios, in: $0) != nil } ?? false
    }

    /// Sends a kept build to Firebase App Distribution so testers elsewhere can install it.
    private func upload(_ p: Platform, _ sha: String) async {
        guard let app = firebaseApp(p) else { return }
        status = "Uploading \(p.label) \(sha.prefix(7)) to Firebase…"
        var file = kept(sha, p)
        if p == .ios {
            // Firebase wants an .ipa, which is just the .app zipped inside a Payload folder.
            // ponytail: this is the development-signed build, so it installs only on devices registered in the
            // Apple developer account. Use an ad hoc export in the iOS build command if testers need more.
            let dir = archive(sha, p)
            _ = await sh("rm -rf Payload app.ipa && mkdir Payload && cp -Rc *.app Payload/ && zip -qry app.ipa Payload; rm -rf Payload", cwd: dir, quiet: true)
            file = q(dir + "/app.ipa")
        }
        let subject = history.first { $0.sha == sha }?.subject ?? ""
        var cmd = "firebase appdistribution:distribute \(file) --app \(q(app)) --release-notes \(q("\(sha.prefix(7)) \(subject)"))"
        if let groups = active.firebaseGroups, !groups.isEmpty { cmd += " --groups \(q(groups))" }
        let ok = await sh(cmd).ok
        if let i = history.firstIndex(where: { $0.sha == sha }) {
            history[i].uploaded = (history[i].uploaded ?? [:]).merging([p.rawValue: ok]) { $1 }
        }
        events.append(ok ? "\(p.label) \(sha.prefix(7)) uploaded to Firebase" : "\(p.label) upload to Firebase failed")
        append("[\(p.label) upload to Firebase \(ok ? "succeeded" : "FAILED")]\n")
    }

    /// History's "Upload to Firebase": sends (or re-sends) a kept build.
    func uploadBuild(_ sha: String) {
        guard !demo, !busy, let project, let record = history.first(where: { $0.sha == sha }) else { return }
        busy = true   // before the task starts, so a second click can't slip in
        Task {
            active = project
            for p in Platform.allCases where record.succeeded(p) { await upload(p, sha) }
            status = "Idle"
            busy = false
            save()
            notifyEvents()
        }
    }

    // MARK: the loop

    enum Run { case auto, build }

    /// One pass: find devices and the latest commit, then build and install as far as `mode` allows.
    /// - auto: what the timer does. Builds and installs for devices with Auto on, unless the project is stopped.
    /// - build: build for every connected device's platform, install nothing.
    func tick(_ mode: Run = .auto) async {
        guard !busy, !demo else { return }
        guard let project else { status = "Choose a project"; return }
        busy = true
        active = project
        defer { busy = false; save(); notifyEvents() }
        if loadedRepo != active.path { load() }

        status = "Looking for devices…"
        await refreshDevices()
        status = "Checking \(active.branch)…"
        guard await fetchLatest(), let sha = latestSHA else {
            status = stopRequested ? "Stopped" : "Couldn't read origin/\(active.branch) — see log"
            return
        }

        let paused = active.paused == true, stopped = paused && mode == .auto
        let wanted = Self.platformsToBuild(mode, paused: paused, sha: sha, devices: devices, built: built, failed: failed,
                                           buildable: Platform.allCases.filter { !active.command($0).isEmpty },
                                           uploads: Platform.allCases.filter { firebaseApp($0) != nil })
        if !wanted.isEmpty, await prepare(sha) {
            for p in wanted where !stopRequested { await build(p, sha) }
        }
        if mode == .auto, !stopped {
            for d in devices where !stopRequested && d.needsInstall(built: built[d.platform]) { await install(d.id) }
        }

        let behind = devices.filter { $0.installedSHA != sha && !active.command($0.platform).isEmpty }
        let waiting = behind.filter(\.auto).count
        status = stopRequested ? "Stopped"
            : failed.contains { $0.value == sha } ? "Build failed — see log"
            : stopped ? (behind.isEmpty ? "Stopped · up to date" : "Stopped · \(sha.prefix(7)) is not on \(behind.count) device\(behind.count == 1 ? "" : "s")")
            : waiting > 0 ? "\(waiting) device\(waiting == 1 ? "" : "s") waiting"
            : "Up to date"
    }

    /// Which platforms a pass should build. No side effects, so the self-check covers it.
    /// A platform is built when the project can build it, something wants it (a connected device, or an upload),
    /// and this commit isn't built yet. The timer skips stopped projects, devices with Auto off, and commits that already failed.
    nonisolated static func platformsToBuild(_ mode: Run, paused: Bool, sha: String, devices: [Device],
                                             built: [Platform: String], failed: [Platform: String],
                                             buildable: [Platform], uploads: [Platform]) -> [Platform] {
        let manual = mode != .auto
        guard manual || !paused else { return [] }
        return buildable.filter { p in
            (devices.contains { $0.platform == p && $0.online && ($0.auto || manual) } || uploads.contains(p))
                && built[p] != sha && (manual || failed[p] != sha)
        }
    }

    /// Asks Xcode and adb directly, so no particular framework has to be installed.
    private func refreshDevices() async {
        let x = await sh("xcrun xcdevice list --timeout 5 2>/dev/null", quiet: true, timeout: 60)
        let sim = await sh("xcrun simctl list devices booted -j 2>/dev/null", quiet: true, timeout: 60)
        let a = await sh("adb devices -l 2>/dev/null", quiet: true, timeout: 60)
        guard x.ok || sim.ok || a.ok else { return }
        let seen = Self.parseXcdevice(x.out) + Self.parseSimctl(sim.out) + Self.parseAdb(a.out)
        for i in devices.indices { devices[i].online = false }
        for s in seen {
            if let i = devices.firstIndex(where: { $0.id == s.id }) {
                devices[i].online = true
                devices[i].name = s.name
                devices[i].connection = s.connection
            } else {
                devices.append(s)
            }
        }
    }

    private nonisolated static func json(_ output: String, from open: Character) -> Any? {
        guard let start = output.firstIndex(of: open) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))
    }

    /// Connected iPhones and iPads from `xcrun xcdevice list`.
    nonisolated static func parseXcdevice(_ output: String) -> [Device] {
        guard let list = json(output, from: "[") as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d["identifier"] as? String, d["simulator"] as? Bool != true,
                  d["available"] as? Bool == true, d["platform"] as? String == "com.apple.platform.iphoneos"
            else { return nil }
            let name = (d["name"] as? String ?? id).trimmingCharacters(in: .whitespaces)
            return Device(id: id, name: name, platform: .ios, online: true,
                          connection: d["interface"] as? String == "usb" ? .wired : .wireless)
        }
    }

    /// Running iOS simulators from `xcrun simctl list devices booted -j`.
    nonisolated static func parseSimctl(_ output: String) -> [Device] {
        guard let runtimes = (json(output, from: "{") as? [String: Any])?["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.filter { $0.key.contains("iOS") }.values.joined().compactMap { d in
            guard let id = d["udid"] as? String, d["state"] as? String == "Booted" else { return nil }
            // Simulators are dev targets you may be running something on: install only when asked.
            return Device(id: id, name: d["name"] as? String ?? id, platform: .iosSim, auto: false, online: true, connection: .simulator)
        }.sorted { $0.name < $1.name }
    }

    /// Android phones and running emulators from `adb devices -l`.
    nonisolated static func parseAdb(_ output: String) -> [Device] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 2, f[1] == "device" else { return nil }   // skips the header, "offline" and "unauthorized"
            let id = f[0], emulator = id.hasPrefix("emulator-")
            let model = f.first { $0.hasPrefix("model:") }.map { $0.dropFirst(6).replacingOccurrences(of: "_", with: " ") }
            // adb names Wi-Fi devices by mDNS service or ip:port, USB ones by serial number
            let connection: Connection = emulator ? .simulator : id.contains("_adb-tls-connect") || id.contains(":") ? .wireless : .wired
            return Device(id: id, name: model ?? id, platform: .android, auto: !emulator, online: true, connection: connection)
        }
    }

    private func fetchLatest() async -> Bool {
        let repo = q(active.path)
        // No --prune: this is the user's own checkout, and deleting its remote branches is not ours to do.
        let fetch = await sh("git -C \(repo) fetch -q origin", quiet: true, timeout: 300)
        guard fetch.ok else { append("[git fetch failed]\n\(fetch.out)\n"); return false }
        let refs = await sh("git -C \(repo) for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin", quiet: true, timeout: 60)
        branches = refs.out.split(separator: "\n").map(String.init).filter { $0 != "HEAD" }
        let r = await sh("git -C \(repo) log -1 --format='%H %s' \(q("origin/" + active.branch))", quiet: true, timeout: 60)
        let parts = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard r.ok, let sha = parts.first else { append("[no branch origin/\(active.branch)]\n\(r.out)\n"); return false }
        latestSHA = String(sha)
        lastChecked = .now
        latestSubject = parts.count > 1 ? String(parts[1]) : ""
        return true
    }

    /// Check the commit out into our own worktree (never the user's checkout) and
    /// bring over the git-ignored files the build needs.
    private func prepare(_ sha: String) async -> Bool {
        status = "Preparing \(sha.prefix(7))…"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: worktree) {
            // prune first: if the build copy was deleted by hand, git still has it registered and refuses to re-add it
            let repo = q(active.path)
            guard await sh("git -C \(repo) worktree prune && git -C \(repo) worktree add -q --detach \(q(worktree)) \(sha)", timeout: 600).ok else { return false }
        }
        var cmd = "git checkout -q --detach \(sha)"
        for p in active.copy.split(separator: " ").map(String.init) {
            let dir = (p as NSString).deletingLastPathComponent
            cmd += " && mkdir -p \(q(dir.isEmpty ? "." : dir)) && rsync -a \(q(active.path + "/" + p)) \(q(dir.isEmpty ? "." : dir))/"
        }
        if let prep = active.prepare, !prep.isEmpty { cmd += " && ( \(prep) )" }
        let ok = await sh(cmd, cwd: worktree).ok
        if !ok, !stopRequested { for p in Platform.allCases { failed[p] = sha } }   // being stopped is not a failure
        return ok
    }

    private func build(_ p: Platform, _ sha: String) async {
        let command = active.command(p)
        guard !command.isEmpty else { return }
        status = "Building \(p.label) \(sha.prefix(7))…"
        var ok = await sh(command, cwd: worktree).ok
        if stopRequested { append("[\(p.label) build stopped]\n"); return }   // not a failure: leave it to be built later
        if ok {
            // Keep a copy per commit for rollback. cp -c clones on APFS, so it costs no time and little disk.
            // ponytail: a * in the artifact path must match exactly one file; several matches break the install.
            let dir = q(archive(sha, p))
            let artifact = q(active.artifact(p)).replacingOccurrences(of: "*", with: "'*'")
            let copy = await sh("rm -rf \(dir) && mkdir -p \(dir) && cp -Rc \(artifact) \(dir)/", cwd: worktree, quiet: true)
            ok = copy.ok
            if !ok { append("[built, but no artifact at \(active.artifact(p)) — check the path in Settings]\n\(copy.out)\n") }
        }
        if ok { built[p] = sha; failed[p] = nil } else { failed[p] = sha; events.append("\(p.label) build failed") }
        append("[\(p.label) build \(ok ? "succeeded" : "FAILED") for \(sha.prefix(7))]\n")
        record(sha, p, ok)
        if ok { await upload(p, sha) }
    }

    private func record(_ sha: String, _ p: Platform, _ ok: Bool) {
        var r = history.first { $0.sha == sha }
            ?? BuildRecord(sha: sha, subject: sha == latestSHA ? latestSubject : "", branch: active.branch, date: .now)
        r.results[p.rawValue] = ok
        r.date = .now
        history.removeAll { $0.sha == sha }
        history.insert(r, at: 0)
        for old in history.dropFirst(keepBuilds) where !built.values.contains(old.sha) {
            try? FileManager.default.removeItem(atPath: "\(home)/builds/\(old.sha)")
            history.removeAll { $0.sha == old.sha }
        }
    }

    /// Installs the kept build of `sha` (default: the newest built one) on a device.
    func install(_ id: String, sha: String? = nil) async {
        guard let i = devices.firstIndex(where: { $0.id == id }), let sha = sha ?? built[devices[i].platform] else { return }
        let d = devices[i]
        let artifact = kept(sha, d.platform)
        status = "Installing on \(d.name)…"
        devices[i].installing = true
        // devicectl / adb -r keep the app's data on the device
        let cmd = switch d.platform {
        case .ios: "xcrun devicectl device install app --device \(q(id)) \(artifact)"
        case .iosSim: "xcrun simctl install \(q(id)) \(artifact)"
        case .android: "adb -s \(q(id)) install -r \(artifact)"
        }
        let r = await sh(cmd, cwd: worktree, quiet: true, timeout: 900)
        guard let j = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[j].installing = false
        if stopRequested { return }
        let error: String? = r.ok ? nil
            : r.out.localizedCaseInsensitiveContains("locked") ? "Locked — unlock it and it will install"
            : r.out.split(separator: "\n").last.map(String.init) ?? "Install failed"
        if error != devices[j].error || r.ok {   // a locked device is retried every pass; log it once
            append("[\(d.name): \(error ?? "installed \(sha.prefix(7))")]\n")
            events.append(r.ok ? "\(d.name) has \(sha.prefix(7))" : "\(d.name): \(error ?? "")")
            if !r.ok { append(r.out + "\n") }
        }
        devices[j].error = error
        if r.ok { devices[j].installedSHA = sha }
    }

    // MARK: buttons

    /// Install button: builds this device's platform first if the latest commit isn't built yet.
    func installNow(_ id: String) {
        guard !demo, !busy, let project, let d = devices.first(where: { $0.id == id }) else { return }
        busy = true
        Task {
            active = project
            if let sha = latestSHA, built[d.platform] != sha, await prepare(sha) { await build(d.platform, sha) }
            await install(id)
            status = built[d.platform] == nil ? "Build failed — see log" : "Idle"
            busy = false
            save()
            notifyEvents()
        }
    }

    /// History's Install: puts a kept build on the given devices. Installing anything but the
    /// newest build turns Auto off for that device, otherwise the next pass would undo it.
    func installBuild(_ sha: String, on ids: [String]) {
        guard !demo, !busy, let project else { return }
        busy = true
        Task {
            active = project
            for id in ids {
                guard let i = devices.firstIndex(where: { $0.id == id }) else { continue }
                if built[devices[i].platform] != sha { devices[i].auto = false }
                await install(id, sha: sha)
            }
            status = "Idle"
            busy = false
            save()
            notifyEvents()
        }
    }

    private func notifyEvents() {
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = active.name
        content.body = events.joined(separator: "\n")
        events = []
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func setAuto(_ id: String, _ on: Bool) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].auto = on
        save()
    }

    func forget(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    // MARK: demo

    private func loadDemo() {
        let new = "4f2c9ab81d3e5f60718293a4b5c6d7e8f9012345", old = "a81b3e7c2d4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b", older = "0c7d55e9f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6"
        projects = [Project(path: "/Users/you/acme-app"), Project(path: "/Users/you/field-notes")]
        for i in projects.indices { projects[i].applyPreset(.flutter) }
        currentPath = projects[0].path
        branches = ["main", "develop", "feature/checkout-redesign"]
        latestSHA = new
        latestSubject = "Merge pull request #218 from acme/feature/checkout-redesign"
        lastChecked = .now
        status = "1 device waiting"
        built = [.ios: new, .android: new, .iosSim: old]
        devices = [
            Device(id: "1", name: "Pixel 9 Pro", platform: .android, installedSHA: new, online: true, connection: .wireless),
            Device(id: "2", name: "iPhone 16 Pro", platform: .ios, installedSHA: new, online: true, connection: .wired),
            Device(id: "3", name: "QA iPad Air", platform: .ios, installedSHA: old,
                   error: "Locked — unlock it and it will install", online: true, connection: .wireless),
            Device(id: "4", name: "iPhone 16 Simulator", platform: .iosSim, auto: false, installedSHA: old, online: true, connection: .simulator),
            Device(id: "5", name: "Galaxy S24", platform: .android, installedSHA: old),
        ]
        history = [
            BuildRecord(sha: new, subject: latestSubject, branch: "main", date: .now.addingTimeInterval(-240),
                        results: ["ios": true, "android": true], uploaded: ["android": true]),
            BuildRecord(sha: old, subject: "Merge pull request #217 from acme/fix/login-timeout", branch: "main",
                        date: .now.addingTimeInterval(-3 * 3600), results: ["ios": true, "android": true, "iosSim": true]),
            BuildRecord(sha: older, subject: "Merge pull request #215 from acme/feature/dark-mode", branch: "main",
                        date: .now.addingTimeInterval(-26 * 3600), results: ["ios": true, "android": false]),
        ]
        log = "$ flutter build apk --release\n✓ Built build/app/outputs/flutter-apk/app-release.apk (42.1MB)\n[Android build succeeded for 4f2c9ab]\n[Pixel 9 Pro: installed 4f2c9ab]\n[iPhone 16 Pro: installed 4f2c9ab]\n[QA iPad Air: Locked — unlock it and it will install]\n"
    }

    // MARK: persistence

    private struct Saved: Codable {
        var devices: [Device]
        var built: [String: String]
        var failed: [String: String]
        var history: [BuildRecord]?
    }

    private func load() {
        loadedRepo = active.path
        devices = []; built = [:]; failed = [:]; history = []
        guard let data = FileManager.default.contents(atPath: stateFile),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        devices = s.devices
        built = Dictionary(uniqueKeysWithValues: s.built.compactMap { k, v in Platform(rawValue: k).map { ($0, v) } })
        failed = Dictionary(uniqueKeysWithValues: s.failed.compactMap { k, v in Platform(rawValue: k).map { ($0, v) } })
        history = s.history ?? []
        // Builds made before history existed have no kept copy: forget them so they are rebuilt once.
        built = built.filter { FileManager.default.fileExists(atPath: archive($0.value, $0.key)) }
    }

    private func save() {
        guard loadedRepo == active.path, !active.path.isEmpty else { return }
        let s = Saved(devices: devices,
                      built: Dictionary(uniqueKeysWithValues: built.map { ($0.key.rawValue, $0.value) }),
                      failed: Dictionary(uniqueKeysWithValues: failed.map { ($0.key.rawValue, $0.value) }),
                      history: history)
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: URL(fileURLWithPath: stateFile), options: .atomic)
    }

    // MARK: shell

    private func append(_ text: String) {
        log += text
        if log.utf8.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    private func q(_ s: String) -> String { shq(s) }

    private var shellEnv: [String: String]?

    /// What a Terminal window would have. An app started from Finder doesn't get anything ~/.zshrc sets up
    /// (ANDROID_HOME, nvm, rbenv, Java…), so ask an interactive login shell once and reuse its answer.
    private func environment() async -> [String: String] {
        if let shellEnv { return shellEnv }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let marker = "__SHIPYARD_ENV__"
        let r = await runShell("/bin/zsh -ilc 'printf \(marker); /usr/bin/env -0' 2>/dev/null", env: env, cwd: nil, timeout: 20)
        if let start = r.out.range(of: marker) {
            for pair in r.out[start.upperBound...].split(separator: "\0") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2, !kv[0].isEmpty { env[String(kv[0])] = String(kv[1]) }
            }
        }
        shellEnv = env
        return env
    }

    /// Runs one command for the active project. Builds get an hour by default; quick queries pass less.
    private func sh(_ command: String, cwd: String? = nil, quiet: Bool = false, timeout: TimeInterval = 3600) async -> (ok: Bool, out: String) {
        if stopRequested { return (false, "") }
        if !quiet { append("$ \(command)\n") }
        var env = await environment()
        // Supplies a signing team when the Xcode project has none set
        if !active.team.isEmpty {
            env["FLUTTER_XCODE_DEVELOPMENT_TEAM"] = active.team   // read by flutter
            env["SHIPYARD_TEAM"] = active.team                    // used by the xcodebuild presets
        }
        var forward: (@Sendable (String) -> Void)?
        if !quiet {
            forward = { [weak self] text in
                Task { @MainActor [weak self] in self?.append(text) }
            }
        }
        let canceller = Canceller()
        running = canceller
        let r = await runShell(command, env: env, cwd: cwd, timeout: timeout, onText: forward, canceller: canceller)
        running = nil
        if r.timedOut { append("[stopped: no result after \(Int(timeout)) seconds]\n") }
        return (r.ok, r.out)
    }
}

/// Quotes a string for the shell.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Kills a process and everything it started, children first so nothing is left holding its output pipe open.
func killTree(_ pid: Int32) {
    let k = Process()
    k.executableURL = URL(fileURLWithPath: "/bin/zsh")
    k.arguments = ["-c", "t() { for c in $(pgrep -P $1); do t $c; done; kill $1 2>/dev/null }; t \(pid)"]
    try? k.run()
    k.waitUntilExit()
}

/// Lets another thread stop a running command, whether it has started yet or not.
final class Canceller: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32 = 0
    private var cancelled = false

    func started(_ p: Int32) {
        lock.lock(); pid = p; let late = cancelled; lock.unlock()
        if late { killTree(p) }
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = pid; lock.unlock()
        if p != 0 { killTree(p) }
    }
}

/// Runs a shell command off the main thread and returns when it ends.
/// - Output is decoded leniently, so a stray non-UTF-8 byte can't stall the reader.
/// - After `timeout` seconds the command and everything it started are killed, so nothing can hang the app forever.
func runShell(_ command: String, env: [String: String], cwd: String?, timeout: TimeInterval,
              onText: (@Sendable (String) -> Void)? = nil, canceller: Canceller? = nil) async -> (ok: Bool, out: String, timedOut: Bool) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription, false) }

        let pid = p.processIdentifier
        canceller?.started(pid)
        let killer = Task.detached {
            try await Task.sleep(for: .seconds(timeout))   // throws if the command finishes first
            killTree(pid)
        }

        var all = Data(), pending = Data()
        while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
            all.append(chunk)
            guard let onText else { continue }
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 0x0A) {   // hand over whole lines only, so characters aren't cut in half
                onText(String(decoding: pending[...newline], as: UTF8.self))
                pending = Data(pending[pending.index(after: newline)...])
            }
        }
        if let onText, !pending.isEmpty { onText(String(decoding: pending, as: UTF8.self)) }
        p.waitUntilExit()
        killer.cancel()
        let timedOut = (try? await killer.value) != nil
        return (p.terminationStatus == 0 && !timedOut, String(decoding: all, as: UTF8.self), timedOut)
    }.value
}

/// `Shipyard --selftest`: the smallest check that fails if device parsing or the queue rule breaks.
func selftest() async {
    // The runner survives bad bytes and gives up on a command that never ends.
    let started = Date()
    let run = await runShell("printf 'a\\377b\\n'; sleep 30", env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 1)
    precondition(run.timedOut && !run.ok && run.out.hasPrefix("a") && Date().timeIntervalSince(started) < 10)
    let fine = await runShell("echo hi; exit 3", env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 10)
    precondition(!fine.ok && !fine.timedOut && fine.out == "hi\n")
    // Stop: a running command and its children die promptly.
    let canceller = Canceller()
    let stopStart = Date()
    Task.detached { try? await Task.sleep(for: .milliseconds(400)); canceller.cancel() }
    let halted = await runShell("sleep 30 & sleep 30; wait", env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 60, canceller: canceller)
    precondition(!halted.ok && !halted.timedOut && Date().timeIntervalSince(stopStart) < 10)

    precondition(shq("it's") == "'it'\\''s'")

    // Saved projects from 0.2.0 (kind stored as its label) and unknown kinds still load.
    let saved = try! JSONDecoder().decode([Project].self, from: Data(#"[{"path":"/a/app","branch":"main","copy":"","flutterArgs":"","team":"","kind":"iOS (Xcode)"},{"path":"/b/app","branch":"main","copy":"","flutterArgs":"","team":"","kind":"someday"}]"#.utf8))
    precondition(saved.map(\.kind) == [.ios, .custom])

    let xc = """
    noise before json
    [{"identifier":"A1","name":" Phone ","platform":"com.apple.platform.iphoneos","available":true,"interface":"usb","simulator":false},
     {"identifier":"A2","name":"Pad","platform":"com.apple.platform.iphoneos","available":true,"interface":"network","simulator":false},
     {"identifier":"A3","name":"Away","platform":"com.apple.platform.iphoneos","available":false,"interface":"network","simulator":false},
     {"identifier":"W1","name":"Watch","platform":"com.apple.platform.watchos","available":true,"interface":"network","simulator":false},
     {"identifier":"S1","name":"Sim","platform":"com.apple.platform.iphonesimulator","available":true,"simulator":true}]
    """
    let i = Engine.parseXcdevice(xc)
    precondition(i.map(\.id) == ["A1", "A2"] && i[0].name == "Phone" && i.map(\.connection) == [.wired, .wireless])

    let sims = Engine.parseSimctl("""
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 16","udid":"S1","state":"Booted"},{"name":"Off","udid":"S2","state":"Shutdown"}],
                "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"name":"Watch","udid":"S3","state":"Booted"}]}}
    """)
    precondition(sims.map(\.id) == ["S1"] && sims[0].platform == .iosSim && !sims[0].auto && sims[0].connection == .simulator)

    let adb = Engine.parseAdb("""
    List of devices attached
    adb-R5GL._adb-tls-connect._tcp device product:m3q model:SM_S948Q device:m3q transport_id:9
    R5GL247    device usb:1-1 product:x model:Pixel_9 device:x transport_id:1
    emulator-5554 device product:sdk model:sdk_gphone64_arm64 device:emu transport_id:2
    ZX1 unauthorized usb:1-2 transport_id:3
    """)
    precondition(adb.map(\.name) == ["SM S948Q", "Pixel 9", "sdk gphone64 arm64"])
    precondition(adb.map(\.connection) == [.wireless, .wired, .simulator] && adb.map(\.auto) == [true, true, false])

    var x = i[0]
    precondition(x.needsInstall(built: "abc") && !x.needsInstall(built: nil))
    x.installedSHA = "abc"; precondition(!x.needsInstall(built: "abc") && x.needsInstall(built: "def"))
    x.auto = false; precondition(!x.needsInstall(built: "def"))
    x.auto = true; x.online = false; precondition(!x.needsInstall(built: "def"))
    // What a pass builds: phone online with Auto on, simulator online with Auto off, tablet offline.
    let fleet = [Device(id: "p", name: "p", platform: .ios, online: true),
                 Device(id: "s", name: "s", platform: .iosSim, auto: false, online: true),
                 Device(id: "t", name: "t", platform: .android)]
    func plan(_ mode: Engine.Run, paused: Bool = false, built: [Platform: String] = [:], failed: [Platform: String] = [:],
              buildable: [Platform] = Platform.allCases, uploads: [Platform] = []) -> [Platform] {
        Engine.platformsToBuild(mode, paused: paused, sha: "new", devices: fleet, built: built, failed: failed, buildable: buildable, uploads: uploads)
    }
    precondition(plan(.auto) == [.ios])                                  // only the connected Auto device
    precondition(plan(.build) == [.ios, .iosSim])                        // Build also covers Auto-off devices
    precondition(plan(.auto, paused: true).isEmpty)                      // stopped: the timer builds nothing
    precondition(plan(.build, paused: true) == [.ios, .iosSim])          // ...but Build still works
    precondition(plan(.auto, built: [.ios: "new"]).isEmpty)              // already built
    precondition(plan(.auto, built: [.ios: "old"]) == [.ios])
    precondition(plan(.auto, failed: [.ios: "new"]).isEmpty)             // don't loop on a broken commit
    precondition(plan(.build, failed: [.ios: "new"]) == [.ios, .iosSim]) // Build retries it
    precondition(plan(.auto, buildable: [.android]).isEmpty)             // no command for iOS; Android device is offline
    precondition(plan(.auto, uploads: [.android]) == [.ios, .android])   // an upload wants it even with no device

    precondition(Engine.parseXcdevice("garbage").isEmpty && Engine.parseSimctl("").isEmpty && Engine.parseAdb("").isEmpty)

    // Project type detection and presets, against throwaway folders
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "shipyard-selftest-\(ProcessInfo.processInfo.processIdentifier)"
    defer { try? fm.removeItem(atPath: root) }
    func make(_ name: String, _ files: [String: String]) -> String {
        for (rel, text) in files {
            let path = "\(root)/\(name)/\(rel)"
            try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if rel.hasSuffix("/") { try! fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
            else { fm.createFile(atPath: path, contents: Data(text.utf8)) }
        }
        return "\(root)/\(name)"
    }
    let rn = make("rn", ["package.json": "{\"dependencies\":{\"react-native\":\"0.76\"}}", "yarn.lock": "",
                         "ios/Podfile": "", "ios/Shop.xcodeproj/": "", "android/build.gradle": ""])
    precondition(Project.detect(make("fl", ["pubspec.yaml": ""])) == .flutter)
    precondition(Project.detect(rn) == .reactNative)
    precondition(Project.detect(make("sw", ["Notes.xcodeproj/": ""])) == .ios)
    precondition(Project.detect(make("kt", ["settings.gradle.kts": ""])) == .android)
    precondition(Project.detect(make("no", ["README.md": ""])) == .custom)
    var proj = Project(path: rn)
    proj.applyPreset(.reactNative)
    precondition(proj.prepare == "yarn install && (cd ios && pod install)")
    precondition(proj.command(.ios).contains("-workspace 'ios/Shop.xcworkspace' -scheme 'Shop'") && proj.command(.ios).contains("-sdk iphoneos"))
    precondition(proj.artifact(.iosSim) == "build/shipyard/Build/Products/Release-iphonesimulator/*.app")
    precondition(proj.command(.android) == "cd android && ./gradlew assembleRelease")
    var swift = Project(path: "\(root)/sw")
    swift.applyPreset(.ios)
    precondition(swift.command(.ios).contains("-project 'Notes.xcodeproj' -scheme 'Notes'") && swift.command(.android).isEmpty)
    print("selftest ok")
}
