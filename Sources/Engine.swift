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

    var buildCommand: String {
        switch self {
        // release, not debug: iOS debug builds won't launch from the home screen
        case .ios: "flutter build ios --release"
        case .android: "flutter build apk --release"   // fat APK, also runs on emulators
        case .iosSim: "flutter build ios --simulator --debug"   // simulators can't run release builds
        }
    }

    var artifact: String {
        switch self {
        case .ios: "build/ios/iphoneos/Runner.app"
        case .android: "build/app/outputs/flutter-apk/app-release.apk"
        case .iosSim: "build/ios/iphonesimulator/Runner.app"
        }
    }
}

enum Connection: String {
    case wired = "USB", wireless = "Wi-Fi", simulator = "Simulator"
}

struct Project: Codable, Identifiable, Equatable {
    var path: String
    var branch = "main"
    var copy = ""          // git-ignored files the build needs, space separated
    var flutterArgs = ""
    var team = ""          // Apple team ID, when the Xcode project has none
    // Firebase App Distribution, for devices that are not on this network. Optional so older saved projects still load.
    var firebaseAndroid: String?   // Firebase app ID; empty = don't upload
    var firebaseIOS: String?
    var firebaseGroups: String?    // tester groups, comma separated

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
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
    var busy = false
    var log = ""

    var project: Project? { projects.first { $0.path == currentPath } }

    var hasFailure: Bool {
        failed.contains { $0.value == latestSHA } || devices.contains { $0.error != nil }
    }

    /// The project a pass is working on. Snapshotted so edits mid-pass can't mix two projects.
    private var active = Project(path: "")
    private var home: String { NSHomeDirectory() + "/.shipyard/" + active.name }   // ponytail: keyed by folder name; two projects with the same folder name would share it
    private var worktree: String { home + "/src" }
    private var stateFile: String { home + "/state.json" }
    private var loadedRepo = ""
    private var events: [String] = []      // what happened this pass, for one notification
    private let keepBuilds = 5             // ponytail: fixed count; each kept build is a few hundred MB
    private func archive(_ sha: String, _ p: Platform) -> String {
        "\(home)/builds/\(sha)/\(p.rawValue)/" + (p.artifact as NSString).lastPathComponent
    }
    private var interval: Int { max(15, UserDefaults.standard.object(forKey: "interval") as? Int ?? 60) }

    /// `Shipyard --demo` shows sample data and touches nothing: for screenshots and trying the UI.
    private let demo = CommandLine.arguments.contains("--demo")

    init() {
        if demo { loadDemo(); return }
        let d = UserDefaults.standard
        if let data = d.data(forKey: "projects"), let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        } else if let repo = d.string(forKey: "repo"), !repo.isEmpty {   // settings from the single-project version
            projects = [Project(path: repo, branch: d.string(forKey: "branch") ?? "main",
                                copy: d.string(forKey: "copy") ?? "",
                                flutterArgs: d.string(forKey: "flutterArgs") ?? "",
                                team: d.string(forKey: "team") ?? "")]
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
        guard FileManager.default.fileExists(atPath: path + "/pubspec.yaml") else {
            status = "That folder has no pubspec.yaml, so it is not a Flutter project"
            return
        }
        if !projects.contains(where: { $0.path == path }) { projects.append(Project(path: path)) }
        select(path)
    }

    func removeCurrentProject() {
        guard !busy else { return }
        projects.removeAll { $0.path == currentPath }
        select(projects.first?.path ?? "")
    }

    func select(_ path: String) {
        guard !busy else { return }
        currentPath = path
        switchTo(project)
    }

    func setBranch(_ branch: String) {
        guard !busy, let i = projects.firstIndex(where: { $0.path == currentPath }) else { return }
        projects[i].branch = branch
        switchTo(project)
    }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.path == project.path }) else { return }
        projects[i] = project
    }

    private func switchTo(_ project: Project?) {
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
        var file = archive(sha, p)
        if p == .ios {
            // Firebase wants an .ipa, which is just the .app zipped inside a Payload folder.
            // ponytail: this is the development-signed build, so it installs only on devices registered in the
            // Apple developer account. Switch to `flutter build ipa --export-method ad-hoc` if testers need more.
            let dir = (file as NSString).deletingLastPathComponent
            _ = await sh("rm -rf Payload Runner.ipa && mkdir Payload && cp -Rc Runner.app Payload/ && zip -qry Runner.ipa Payload; rm -rf Payload", cwd: dir, quiet: true)
            file = dir + "/Runner.ipa"
        }
        let subject = history.first { $0.sha == sha }?.subject ?? ""
        var cmd = "firebase appdistribution:distribute \(q(file)) --app \(q(app)) --release-notes \(q("\(sha.prefix(7)) \(subject)"))"
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
        Task {
            busy = true
            active = project
            for p in Platform.allCases where record.succeeded(p) { await upload(p, sha) }
            status = "Idle"
            busy = false
            save()
            notifyEvents()
        }
    }

    // MARK: the loop

    /// One pass: find devices, look for a new commit, build if needed, install where pending.
    func tick(force: Bool = false) async {
        guard !busy, !demo else { return }
        guard let project else { status = "Choose a Flutter project"; return }
        busy = true
        active = project
        defer { busy = false; save(); notifyEvents() }
        if loadedRepo != active.path { load() }

        status = "Looking for devices…"
        await refreshDevices()
        status = "Checking \(active.branch)…"
        guard await fetchLatest(), let sha = latestSHA else {
            status = "Couldn't read origin/\(active.branch) — see log"
            return
        }

        // Build only for platforms a connected device is waiting on; offline ones build when they return.
        let wanted = Platform.allCases.filter { p in
            (devices.contains { $0.platform == p && $0.online && ($0.auto || force) } || firebaseApp(p) != nil)
                && built[p] != sha && (force || failed[p] != sha)
        }
        if !wanted.isEmpty, await prepare(sha) {
            for p in wanted { await build(p, sha) }
        }
        for d in devices where d.needsInstall(built: built[d.platform]) { await install(d.id) }

        let pending = devices.filter { $0.auto && $0.installedSHA != sha }.count
        status = failed.contains { $0.value == sha } ? "Build failed — see log"
            : pending > 0 ? "\(pending) device\(pending == 1 ? "" : "s") waiting"
            : "Up to date"
    }

    private func refreshDevices() async {
        let r = await sh("flutter devices --machine --device-timeout 10 2>/dev/null", quiet: true)
        guard r.ok else { return }
        var seen = Self.parseDevices(r.out)
        if seen.contains(where: { $0.platform == .ios }) {
            // Flutter doesn't say how an iPhone is connected; devicectl does.
            let file = NSTemporaryDirectory() + "shipyard-devices.json"
            _ = await sh("xcrun devicectl list devices --json-output \(q(file))", quiet: true)
            let transports = Self.parseTransports((try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data())
            for i in seen.indices where seen[i].platform == .ios {
                seen[i].connection = transports[seen[i].id] ?? .wired
            }
        }
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

    /// iOS/Android devices, simulators and emulators from `flutter devices --machine` output.
    nonisolated static func parseDevices(_ output: String) -> [Device] {
        guard let start = output.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { d in
            guard let id = d["id"] as? String, let target = d["targetPlatform"] as? String,
                  target == "ios" || target.hasPrefix("android")
            else { return nil }
            let simulated = d["emulator"] as? Bool == true
            let platform: Platform = target != "ios" ? .android : simulated ? .iosSim : .ios
            // adb names Wi-Fi devices by mDNS service or ip:port, USB ones by serial number
            let connection: Connection = simulated ? .simulator
                : platform == .android && (id.contains("_adb-tls-connect") || id.contains(":")) ? .wireless : .wired
            let name = (d["name"] as? String ?? id).trimmingCharacters(in: .whitespaces)
            // Simulators are dev targets you may be running something on: install only when asked.
            return Device(id: id, name: name, platform: platform, auto: !simulated, online: true, connection: connection)
        }
    }

    /// UDID -> connection type from `xcrun devicectl list devices --json-output`.
    nonisolated static func parseTransports(_ json: Data) -> [String: Connection] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [:] }
        var out: [String: Connection] = [:]
        for d in list {
            guard let udid = (d["hardwareProperties"] as? [String: Any])?["udid"] as? String,
                  let transport = (d["connectionProperties"] as? [String: Any])?["transportType"] as? String
            else { continue }
            out[udid] = transport == "wired" ? .wired : .wireless
        }
        return out
    }

    private func fetchLatest() async -> Bool {
        let repo = q(active.path)
        let fetch = await sh("git -C \(repo) fetch -q --prune origin", quiet: true)
        guard fetch.ok else { append("[git fetch failed]\n\(fetch.out)\n"); return false }
        let refs = await sh("git -C \(repo) for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin", quiet: true)
        branches = refs.out.split(separator: "\n").map(String.init).filter { $0 != "HEAD" }
        let r = await sh("git -C \(repo) log -1 --format='%H %s' \(q("origin/" + active.branch))", quiet: true)
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
            guard await sh("git -C \(q(active.path)) worktree add -q --detach \(q(worktree)) \(sha)").ok else { return false }
        }
        var cmd = "git checkout -q --detach \(sha)"
        for p in active.copy.split(separator: " ").map(String.init) {
            let dir = (p as NSString).deletingLastPathComponent
            cmd += " && mkdir -p \(q(dir.isEmpty ? "." : dir)) && rsync -a \(q(active.path + "/" + p)) \(q(dir.isEmpty ? "." : dir))/"
        }
        cmd += " && flutter pub get"
        let ok = await sh(cmd, cwd: worktree).ok
        if !ok { for p in Platform.allCases { failed[p] = sha } }
        return ok
    }

    private func build(_ p: Platform, _ sha: String) async {
        status = "Building \(p.label) \(sha.prefix(7))…"
        var ok = await sh("\(p.buildCommand) \(active.flutterArgs)", cwd: worktree).ok
        if ok {
            // Keep a copy per commit for rollback. cp -c clones on APFS, so it costs no time and little disk.
            let dest = archive(sha, p)
            let dir = (dest as NSString).deletingLastPathComponent
            ok = await sh("rm -rf \(q(dir)) && mkdir -p \(q(dir)) && cp -Rc \(q(p.artifact)) \(q(dir))/", cwd: worktree, quiet: true).ok
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
        let artifact = q(archive(sha, d.platform))
        status = "Installing on \(d.name)…"
        devices[i].installing = true
        // devicectl / adb -r rather than `flutter install`, which uninstalls first and wipes app data
        let cmd = switch d.platform {
        case .ios: "xcrun devicectl device install app --device \(q(id)) \(artifact)"
        case .iosSim: "xcrun simctl install \(q(id)) \(artifact)"
        case .android: "adb -s \(q(id)) install -r \(artifact)"
        }
        let r = await sh(cmd, cwd: worktree, quiet: true)
        guard let j = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[j].installing = false
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

    func buildNow() { Task { await tick(force: true) } }

    /// Install button: builds this device's platform first if the latest commit isn't built yet.
    func installNow(_ id: String) {
        guard !demo, !busy, let project, let d = devices.first(where: { $0.id == id }) else { return }
        Task {
            busy = true
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
        Task {
            busy = true
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
        try? JSONEncoder().encode(s).write(to: URL(fileURLWithPath: stateFile))
    }

    // MARK: shell

    private func append(_ text: String) {
        log += text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs a command in a login shell, so Homebrew's flutter/adb are on PATH like in Terminal.
    private func sh(_ command: String, cwd: String? = nil, quiet: Bool = false) async -> (ok: Bool, out: String) {
        if !quiet { append("$ \(command)\n") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        // Supplies a signing team when the Xcode project has none set
        if !active.team.isEmpty { env["FLUTTER_XCODE_DEVELOPMENT_TEAM"] = active.team }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return (false, "\(error.localizedDescription)") }
        var out = ""
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                out += line + "\n"
                if !quiet { append(line + "\n") }
            }
        } catch {}
        p.waitUntilExit()   // output hit EOF, so the process is already exiting
        return (p.terminationStatus == 0, out)
    }
}

/// `Shipyard --selftest`: the smallest check that fails if device parsing or the queue rule breaks.
func selftest() {
    let json = """
    noise before json
    [{"id":"A1","name":" Phone ","targetPlatform":"ios","emulator":false},
     {"id":"sim","name":"Sim","targetPlatform":"ios","emulator":true},
     {"id":"adb-1._adb-tls-connect._tcp","name":"Pixel","targetPlatform":"android-arm64","emulator":false},
     {"id":"R5GL247","name":"Galaxy","targetPlatform":"android-arm64","emulator":false},
     {"id":"emulator-5554","name":"Emu","targetPlatform":"android-x64","emulator":true},
     {"id":"macos","name":"macOS","targetPlatform":"darwin","emulator":false}]
    """
    let d = Engine.parseDevices(json)
    precondition(d.map(\.id) == ["A1", "sim", "adb-1._adb-tls-connect._tcp", "R5GL247", "emulator-5554"])
    precondition(d.map(\.platform) == [.ios, .iosSim, .android, .android, .android] && d[0].name == "Phone")
    precondition(d.map(\.connection) == [.wired, .simulator, .wireless, .wired, .simulator])
    precondition(d.map(\.auto) == [true, false, true, true, false])   // simulators install only when asked
    var x = d[0]
    precondition(x.needsInstall(built: "abc") && !x.needsInstall(built: nil))
    x.installedSHA = "abc"; precondition(!x.needsInstall(built: "abc") && x.needsInstall(built: "def"))
    x.auto = false; precondition(!x.needsInstall(built: "def"))
    x.auto = true; x.online = false; precondition(!x.needsInstall(built: "def"))
    precondition(Engine.parseDevices("garbage").isEmpty)

    let ctl = """
    {"result":{"devices":[
      {"hardwareProperties":{"udid":"A1"},"connectionProperties":{"transportType":"localNetwork"}},
      {"hardwareProperties":{"udid":"B2"},"connectionProperties":{"transportType":"wired"}},
      {"hardwareProperties":{"udid":"C3"},"connectionProperties":{}}]}}
    """
    let t = Engine.parseTransports(Data(ctl.utf8))
    precondition(t == ["A1": .wireless, "B2": .wired])
    print("selftest ok")
}
