import SwiftUI
import UIKit

// MARK: - Guest paths
//
// The runtime stores a guest filesystem under the root's own directory: fakefs
// roots keep guest paths below `data/`, realfs roots do not. Resolve against
// both so a screen works on either layout instead of assuming one.

enum GuestPath {
    static func host(root: String, guest: String) -> URL? {
        let base = LRRuntimeBridge.rootURL(root)
        let leaf = guest.hasPrefix("/") ? String(guest.dropFirst()) : guest
        for candidate in [base.appendingPathComponent("data"), base] {
            let url = candidate.appendingPathComponent(leaf)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) { return url }
        }
        return nil
    }

    /// Regular files only: no symlinks, no devices, nothing that could block a read.
    static func files(root: String, guest: String) -> [(name: String, url: URL, size: Int64, modified: Date?)] {
        guard let directory = host(root: root, guest: guest) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let listing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return listing.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url.lastPathComponent, url, Int64(values.fileSize ?? 0), values.contentModificationDate)
        }.sorted { $0.name < $1.name }
    }

    static func names(root: String, guest: String) -> [String] {
        guard let directory = host(root: root, guest: guest) else { return [] }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return listing.filter { !$0.hasPrefix(".") }.sorted()
    }
}

// MARK: - Updates

struct PackageUpdate: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let current: String
    let available: String
}

/// Runs the bundled `package-manager.sh` `updates` operation without showing a
/// terminal, then reads the operation log it leaves in the support folder.
@MainActor final class UpdateModel: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var updates: [PackageUpdate] = []
    @Published private(set) var raw = ""
    @Published private(set) var checkedAt: Date?
    @Published private(set) var failure: String?

    private let support: URL
    private var controller: TerminalViewController?
    private var poll: Timer?
    private var deadline = Date.distantFuture

    init(root: String) {
        support = LRRuntimeBridge.exchangeURL(root).appendingPathComponent(".linuxrunner/gui")
    }

    var hasOutput: Bool { !raw.isEmpty }

    func check() {
        guard !checking else { return }
        guard LRRuntimeBridge.isRunning() else { failure = LRRuntimeBridge.runtimeStatus(); return }
        do {
            let command = try PackageOperation.command("updates")
            // A stale result from an earlier operation would look like an
            // instant success, so drop it before starting the session.
            try? FileManager.default.removeItem(at: support.appendingPathComponent("package-result"))
            checking = true; failure = nil; updates = []; raw = ""
            controller = LRRuntimeBridge.terminal(forCommand: command, directory: "/root")
            deadline = Date().addingTimeInterval(180)
            poll?.invalidate()
            poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] timer in
                Task { @MainActor in self?.step(timer) }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func step(_ timer: Timer) {
        let result = (try? String(contentsOf: support.appendingPathComponent("package-result"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finished = Int(result) != nil
        if !finished && Date() < deadline { return }
        timer.invalidate(); poll = nil; checking = false
        controller = nil
        guard finished else { failure = "The package manager did not finish. Check the terminal and try again."; return }

        let log = LRRuntimeBridge.boundedDiagnosticTail(support.appendingPathComponent("package-operation.log"), maxBytes: 262144)
        raw = log
        updates = Self.parse(log)
        checkedAt = Date()
        if result != "0" && updates.isEmpty {
            failure = "The package manager reported exit \(result). Last output is shown below."
        }
    }

    /// Package manager output is not a stable interface, so this recognises the
    /// four documented formats and otherwise leaves the raw log for the reader.
    static func parse(_ log: String) -> [PackageUpdate] {
        var found: [PackageUpdate] = []
        var seen = Set<String>()
        func add(_ name: String, _ current: String, _ available: String) {
            let clean = name.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, PackageOperation.validName(clean), seen.insert(clean).inserted else { return }
            found.append(PackageUpdate(name: clean, current: current, available: available))
        }
        for rawLine in log.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // pacman -Qu: "name 1.2.3-1 -> 1.2.4-1"
            if let match = line.range(of: #"^(\S+) (\S+) -> (\S+)$"#, options: .regularExpression) {
                let parts = String(line[match]).components(separatedBy: " ")
                if parts.count == 4 { add(parts[0], parts[1], parts[3]); continue }
            }
            // apt list --upgradable: "name/suite 1.2.3 arm64 [upgradable from: 1.2.2]"
            if line.contains("/"), let bracket = line.range(of: "[upgradable from: ") {
                let head = line[..<bracket.lowerBound].split(separator: " ")
                let current = line[bracket.upperBound...].split(separator: "]").first.map(String.init) ?? ""
                if head.count >= 2 {
                    let name = head[0].split(separator: "/").first.map(String.init) ?? ""
                    add(name, current.trimmingCharacters(in: .whitespaces), String(head[1]))
                    continue
                }
            }
            // apk version -l '<': "name-1.2.3-r0 < 1.2.4-r0"
            if let less = line.range(of: " < ") {
                let left = line[..<less.lowerBound].split(separator: " ").last.map(String.init) ?? ""
                let right = line[less.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if let dash = left.lastIndex(of: "-"), dash > left.startIndex {
                    add(String(left[..<dash]), String(left[left.index(after: dash)...]), right)
                    continue
                }
            }
            // dnf check-upgrade rows: "name.arch  version  repo  size"
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 3, !line.hasPrefix("Last"), !line.hasPrefix("Name"),
               let dot = fields[0].lastIndex(of: "."), fields[0].index(after: dot) < fields[0].endIndex,
               fields[1].first?.isNumber == true {
                add(String(fields[0][..<dot]), "", String(fields[1]))
            }
        }
        return found
    }

    /// Full upgrade as the distribution's own tool would run it, with its own
    /// confirmation prompt: the app never applies a transaction silently.
    static func upgradeCommand(packageManager: String?, elevation: String) -> String {
        switch (packageManager ?? "").lowercased() {
        case "apt": return "\(elevation)apt-get update && \(elevation)apt-get --no-install-recommends --no-remove full-upgrade"
        case "pacman": return "\(elevation)pacman -Syu"
        case "dnf": return "\(elevation)dnf upgrade"
        case "apk": return "\(elevation)apk update && \(elevation)apk upgrade"
        default: return ""
        }
    }

    static func refreshCommand(packageManager: String?, elevation: String) -> String {
        switch (packageManager ?? "").lowercased() {
        case "apt": return "\(elevation)apt-get update"
        case "pacman": return "\(elevation)pacman -Sy"
        case "dnf": return "\(elevation)dnf --refresh makecache"
        case "apk": return "\(elevation)apk update"
        default: return ""
        }
    }
}

struct UpdatesView: View {
    let environment: LinuxEnvironment
    @StateObject private var model: UpdateModel
    @State private var session: TerminalViewControllerRef?
    @State private var unsupported: String?

    init(environment: LinuxEnvironment) {
        self.environment = environment
        _model = StateObject(wrappedValue: UpdateModel(root: environment.rootfsName))
    }

    private var elevation: String { QuickCommandStore.elevation }

    var body: some View {
        List {
            Section {
                if !LRRuntimeBridge.isRunning() {
                    Text("Start the runtime to check for updates.").foregroundColor(.secondary)
                } else if environment.distributionID == "steamos" {
                    Text("SteamOS ARM64 is an inspection-only experiment; repository updates are disabled for that image.").foregroundColor(.secondary)
                } else if model.checking {
                    HStack(spacing: 10) { ProgressView(); Text("Querying \(environment.name)…") }
                } else if !model.updates.isEmpty {
                    ForEach(model.updates) { update in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.name).font(.system(.body, design: .monospaced))
                            Text(update.current.isEmpty ? update.available : "\(update.current) → \(update.available)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else if model.checkedAt != nil {
                    Text("No updates available.").foregroundColor(.secondary)
                } else {
                    Text("Check for updates to query \(environment.name)'s package manager. This reads package metadata; it installs nothing.").foregroundColor(.secondary)
                }
            } header: {
                Text("Available updates")
            } footer: {
                if let checked = model.checkedAt {
                    Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened)) · \(model.updates.count) package\(model.updates.count == 1 ? "" : "s")")
                } else {
                    Text("Uses the distribution's own updater: apt (Debian, Kali), pacman (Arch), dnf (Fedora), apk (Alpine).")
                }
            }

            if let failure = model.failure {
                Section { Text(failure).font(.caption).foregroundColor(.orange) }
            }

            if model.hasOutput, model.updates.isEmpty {
                Section("Package manager output") {
                    Text(String(model.raw.suffix(4000))).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }

            Section {
                Button { model.check() } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.checking || !LRRuntimeBridge.isRunning() || environment.distributionID == "steamos")

                Button {
                    run(UpdateModel.upgradeCommand(packageManager: environment.packageManager, elevation: elevation))
                } label: {
                    Label("Upgrade All in Terminal", systemImage: "arrow.down.circle")
                }
                .disabled(!LRRuntimeBridge.isRunning() || environment.distributionID == "steamos")

                Button {
                    run(UpdateModel.refreshCommand(packageManager: environment.packageManager, elevation: elevation))
                } label: {
                    Label("Refresh Package Lists", systemImage: "arrow.clockwise")
                }
                .disabled(!LRRuntimeBridge.isRunning() || environment.distributionID == "steamos")
            } footer: {
                Text("The upgrade opens in a terminal and the package manager asks for its own confirmation; review the transaction before accepting it.")
            }
        }
        .navigationTitle("Updates")
        .fullScreenCover(item: $session) { TerminalScreen(controller: $0.controller) }
        .alert("Updates", isPresented: Binding(get: { unsupported != nil }, set: { if !$0 { unsupported = nil } })) {
            Button("OK") { unsupported = nil }
        } message: {
            Text(unsupported ?? "")
        }
    }

    private func run(_ command: String) {
        guard !command.isEmpty else { unsupported = "No package manager is recorded for this environment."; return }
        session = TerminalViewControllerRef(controller: LRRuntimeBridge.terminal(forCommand: ["/bin/sh", "-c", command], directory: "/root"))
    }
}

struct TerminalViewControllerRef: Identifiable {
    let id = UUID()
    let controller: TerminalViewController
}

// MARK: - Init scripts

/// There is no init system in this runtime: nothing starts a service manager at
/// boot. What a distribution ships in /etc/init.d still works when invoked, so
/// the app lists those scripts and runs the action in a terminal.
struct ServicesView: View {
    let environment: LinuxEnvironment
    @State private var scripts: [String] = []
    @State private var session: TerminalViewControllerRef?
    @State private var query = ""

    private var elevation: String { QuickCommandStore.elevation }

    private var shown: [String] {
        query.isEmpty ? scripts : scripts.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    var body: some View {
        List {
            if scripts.isEmpty {
                Section {
                    Text("No init scripts were found for \(environment.name).").foregroundColor(.secondary)
                    Text("This runtime has no init system: Debian-family and Alpine images usually ship /etc/init.d scripts, while Arch and Fedora images rely on units that cannot run without systemd. Long-running work started here keeps running while the runtime does.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(shown, id: \.self) { name in
                        Menu {
                            Button("Start") { run(name, "start") }
                            Button("Status") { run(name, "status") }
                            Button("Restart") { run(name, "restart") }
                            Button("Stop", role: .destructive) { run(name, "stop") }
                        } label: {
                            HStack {
                                Image(systemName: "gearshape.2.fill").foregroundColor(.accentColor).frame(width: 24)
                                Text(name).font(.system(.body, design: .monospaced))
                                Spacer()
                                Image(systemName: "chevron.right.2").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(scripts.count) scripts")
                } footer: {
                    Text("Each action runs /etc/init.d/<script> in a terminal, so its output and errors are visible. Status reports what the script itself reports.")
                }
            }
        }
        .navigationTitle("Services")
        .searchable(text: $query, prompt: "Filter scripts")
        .onAppear(perform: load)
        .fullScreenCover(item: $session) { TerminalScreen(controller: $0.controller) }
    }

    private func load() {
        var names = Set(GuestPath.names(root: environment.rootfsName, guest: "/etc/init.d"))
        names.formUnion(GuestPath.names(root: environment.rootfsName, guest: "/etc/rc.d/init.d"))
        scripts = names.filter(valid).sorted()
    }

    private func run(_ name: String, _ action: String) {
        guard valid(name), LRRuntimeBridge.isRunning() else { return }
        let line = "\(elevation)/etc/init.d/\(name) \(action)"
        session = TerminalViewControllerRef(controller: LRRuntimeBridge.terminal(forCommand: ["/bin/sh", "-c", line], directory: "/"))
    }
}

// MARK: - System logs

struct LogFile: Identifiable {
    var id: String { name }
    let name: String
    let url: URL
    let size: Int64
    let modified: Date?
}

struct SystemLogsView: View {
    let environment: LinuxEnvironment
    @State private var files: [LogFile] = []
    @State private var query = ""
    @State private var selected: LogFile?

    private var shown: [LogFile] {
        query.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if files.isEmpty {
                Section {
                    Text("No log files under /var/log for \(environment.name).").foregroundColor(.secondary)
                    Text("Some images keep logs only in memory (journald) or have not written any yet. Container-style root filesystems can also store the tree under a different layout; this screen reads the files the runtime keeps on disk.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(shown) { file in
                        Button { selected = file } label: {
                            HStack {
                                Image(systemName: file.name.hasSuffix(".gz") ? "archivebox" : "doc.text")
                                    .foregroundColor(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).font(.system(.body, design: .monospaced)).foregroundColor(.primary)
                                    if let modified = file.modified {
                                        Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(modified.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(files.count) files")
                } footer: {
                    Text("Read-only view of the last 64 KB of each file. Compressed logs are listed but shown as-is.")
                }
            }
        }
        .navigationTitle("System Logs")
        .searchable(text: $query, prompt: "Filter log files")
        .onAppear(perform: load)
        .refreshable { load() }
        .sheet(item: $selected) { file in
            NavigationView { LogTailView(file: file) }
        }
    }

    private func load() {
        files = GuestPath.files(root: environment.rootfsName, guest: "/var/log").map {
            LogFile(name: $0.name, url: $0.url, size: $0.size, modified: $0.modified)
        }
        // Newest first: the file a reader wants is usually the one that changed.
        files.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

private struct LogTailView: View {
    let file: LogFile
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var share: ExportItem?

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Empty file." : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { exportTail() } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            text = LRRuntimeBridge.boundedDiagnosticTail(file.url, maxBytes: 65536)
        }
        .sheet(item: $share) { ShareView(item: $0) }
    }

    private func exportTail() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.name)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        share = ExportItem(url: url)
    }
}
