import SwiftUI
import UIKit

// MARK: - Quick commands
//
// Saved shell one-liners that run in a terminal. The command list is native
// state only: it never touches the guest, and each run goes through the same
// terminal path the application launcher uses.

struct QuickCommand: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var line: String

    static let symbols = [
        "terminal", "arrow.down.circle", "internaldrive", "memorychip", "network",
        "magnifyingglass", "trash", "clock", "gearshape.2", "rectangle.stack",
    ]
}

@MainActor final class QuickCommandStore: ObservableObject {
    private static let key = "LinuxRunner.quickCommands.v1"
    @Published private(set) var commands: [QuickCommand] = []

    init(seedIfEmpty: Bool = true) {
        load()
        if commands.isEmpty, seedIfEmpty { commands = Self.defaults() }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([QuickCommand].self, from: data) else { return }
        commands = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func add(_ command: QuickCommand) { commands.append(command); persist() }
    func replace(_ command: QuickCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command; persist()
    }
    func delete(at offsets: IndexSet) { commands.remove(atOffsets: offsets); persist() }
    func move(from source: IndexSet, to destination: Int) { commands.move(fromOffsets: source, toOffset: destination); persist() }
    func reset() { commands = Self.defaults(); persist() }

    /// Elevation prefix for the active environment: root needs none, and a
    /// distribution without sudo falls back to plain commands.
    static var elevation: String {
        LRRuntimeBridge.defaultLinuxUser() == "root" ? "" : "sudo "
    }

    static func updateCommand(for packageManager: String?) -> String {
        let sudo = elevation
        switch (packageManager ?? "").lowercased() {
        case "apt": return "\(sudo)apt update && \(sudo)apt full-upgrade -y && \(sudo)apt autoremove -y"
        case "pacman": return "\(sudo)pacman -Syu --noconfirm"
        case "dnf": return "\(sudo)dnf upgrade -y"
        case "apk": return "\(sudo)apk update && \(sudo)apk upgrade"
        default: return "echo 'No package manager detected for this environment.'"
        }
    }

    static func defaults() -> [QuickCommand] {
        let manager = activeEnvironment()?.packageManager
        let home = activeEnvironment()?.homePath ?? "/"
        return [
            QuickCommand(name: "Update packages", symbol: "arrow.down.circle", line: updateCommand(for: manager)),
            QuickCommand(name: "System information", symbol: "gearshape.2",
                         line: "uname -a; echo; cat /etc/os-release 2>/dev/null | head -6; echo; df -h / \(home) 2>/dev/null"),
            QuickCommand(name: "Disk usage", symbol: "internaldrive", line: "df -h"),
            QuickCommand(name: "Memory", symbol: "memorychip", line: "free -m 2>/dev/null || head -5 /proc/meminfo"),
            QuickCommand(name: "Processes", symbol: "rectangle.stack", line: "ps aux 2>/dev/null | head -20 || ps | head -20"),
            QuickCommand(name: "Largest directories", symbol: "magnifyingglass",
                         line: "du -xh /usr /var /home /root 2>/dev/null | sort -rh | head -15"),
            QuickCommand(name: "Open ports", symbol: "network", line: "ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || echo 'Install iproute2 or net-tools for this view.'"),
            QuickCommand(name: "Recent system log", symbol: "clock", line: "tail -n 40 /var/log/messages 2>/dev/null || journalctl -n 40 --no-pager 2>/dev/null || dmesg | tail -n 40"),
        ]
    }

    private static func activeEnvironment() -> LinuxEnvironment? {
        let root = LRRuntimeBridge.activeRootName()
        let catalog = try? EnvironmentCatalog.read(LRRuntimeBridge.catalogURL())
        return catalog?.environments.first { $0.rootfsName == root } ?? catalog?.environments.first
    }
}

private struct QuickSession: Identifiable {
    let id = UUID()
    let controller: TerminalViewController
}

struct QuickCommandsView: View {
    @StateObject private var store = QuickCommandStore()
    @State private var editing: QuickCommand?
    @State private var creating = false
    @State private var session: QuickSession?
    @State private var failure: String?
    @State private var confirmReset = false

    private var running: Bool { LRRuntimeBridge.isRunning() }

    var body: some View {
        List {
            if !running {
                Section {
                    Label("Start the runtime to run commands.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(LRRuntimeBridge.runtimeStatus()).font(.caption).foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(store.commands) { command in
                    Button {
                        run(command)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: command.symbol)
                                .frame(width: 24).foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(command.name).foregroundColor(.primary)
                                Text(command.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "play.circle").foregroundColor(.secondary)
                        }
                    }
                    .disabled(!running)
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(command) }
                        Button("Edit") { editing = command }.tint(.blue)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { store.delete(at: $0) }
            } header: {
                Text("Commands")
            } footer: {
                Text("Each command runs as /bin/sh -c in a fresh terminal. Swipe a row to edit or delete it; drag to reorder.")
            }
        }
        .navigationTitle("Quick Commands")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") } }
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $editing) { command in
            NavigationView { QuickCommandEditor(command: command) { store.replace($0) } }
        }
        .sheet(isPresented: $creating) {
            NavigationView { QuickCommandEditor(command: nil) { store.add($0) } }
        }
        .fullScreenCover(item: $session) { TerminalScreen(controller: $0.controller) }
        .confirmationDialog("Replace your quick commands with the defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Command", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func run(_ command: QuickCommand) {
        guard running else { failure = LRRuntimeBridge.runtimeStatus(); return }
        let controller = LRRuntimeBridge.terminal(forCommand: ["/bin/sh", "-c", command.line], directory: "/")
        session = QuickSession(controller: controller)
    }

    private func delete(_ command: QuickCommand) {
        if let index = store.commands.firstIndex(where: { $0.id == command.id }) {
            store.delete(at: IndexSet(integer: index))
        }
    }
}

private struct QuickCommandEditor: View {
    private static let blank = QuickCommand(name: "", symbol: "terminal", line: "echo hello")
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuickCommand
    private let isNew: Bool
    private let save: (QuickCommand) -> Void

    init(command: QuickCommand?, save: @escaping (QuickCommand) -> Void) {
        _draft = State(initialValue: command ?? Self.blank)
        isNew = command == nil
        self.save = save
    }

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                // TextEditor rather than a multi-line TextField: `axis: .vertical`
                // needs iOS 16 and this app deploys to 15.
                TextEditor(text: $draft.line)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 76)
            } footer: {
                Text("Runs as /bin/sh -c, so pipes, && and redirections work. Quote paths that contain spaces.")
            }
            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                    ForEach(QuickCommand.symbols, id: \.self) { symbol in
                        Button {
                            draft.symbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(symbol == draft.symbol ? Color.accentColor.opacity(0.2) : Color.clear))
                                .foregroundColor(symbol == draft.symbol ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Command" : "Edit Command")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(draft); dismiss() }.disabled(!valid)
            }
        }
    }
}

// MARK: - Ops dashboard

@MainActor private final class OpsSnapshot: ObservableObject {
    @Published var tasks: [[String: Any]] = []
    @Published var health: [String: Any] = [:]
    @Published var alerts: [[String: Any]] = []
    @Published var footprint: UInt64 = 0
    @Published var free: Int64?

    func refresh() {
        tasks = LRRuntimeBridge.taskSnapshot()
        health = LRRuntimeBridge.healthSummary() as? [String: Any] ?? [:]
        footprint = LRRuntimeBridge.appFootprintBytes()
        let entries = (LRRuntimeBridge.diagnosticEntries() as? [[String: Any]]) ?? []
        // Anything above the informational levels: these are the records worth
        // surfacing without opening the full diagnostics screen.
        let interesting = Set(["WARNING", "WARN", "ERROR", "FAULT", "CRITICAL"])
        alerts = Array(entries.reversed().filter { interesting.contains(($0["level"] as? String ?? "").uppercased()) }.prefix(6))
        free = (try? LRRuntimeBridge.managedStorageURL()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    var topProcesses: [[String: Any]] {
        tasks.sorted { ($0["anonymous_kb"] as? Int ?? 0) > ($1["anonymous_kb"] as? Int ?? 0) }.prefix(4).map { $0 }
    }
}

struct OpsDashboardView: View {
    @ObservedObject var manager: EnvironmentManager
    @StateObject private var snapshot = OpsSnapshot()
    @State private var share: ExportItem?
    @State private var failure: String?
    @State private var cleaning = false
    @State private var showTasks = false
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func kilobytes(_ value: Int) -> String { bytes(Int64(value) * 1024) }

    var body: some View {
        List {
            Section("Runtime") {
                row("Status", LRRuntimeBridge.isRunning() ? "Running" : "Stopped")
                row("Environment", environmentName)
                row("Backend", backend)
                row("Guest processes", "\(snapshot.tasks.count)")
                row("App memory", bytes(Int64(snapshot.footprint)))
                if let free = snapshot.free { row("Free storage", bytes(free)) }
            }

            Section {
                if snapshot.topProcesses.isEmpty {
                    Text("No guest processes. Start the runtime to see them.").foregroundColor(.secondary)
                }
                ForEach(Array(snapshot.topProcesses.enumerated()), id: \.offset) { _, task in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task["name"] as? String ?? "?").font(.system(.body, design: .monospaced))
                            Text("PID \(task["pid"] as? Int ?? 0) · \(task["threads"] as? Int ?? 0) threads").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(kilobytes(task["anonymous_kb"] as? Int ?? 0)).font(.caption).foregroundColor(.secondary)
                    }
                }
                Button("Open Task Manager") { showTasks = true }
            } header: {
                Text("Top processes by memory")
            } footer: {
                Text("Mapped address space, not host residency. Live CPU sampling is in Task Manager.")
            }

            if !manager.environments.isEmpty {
                Section("Environments") {
                    ForEach(manager.environments) { environment in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(environment.name)
                                Text("\(environment.distribution) \(environment.rootfsVersion)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(manager.size(environment)).font(.caption)
                                Text(manager.active(environment) ? "Active" : "Installed").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    NavigationLink("Manage Storage", destination: StorageManagementView(environments: manager.environments))
                }
            }

            Section {
                if snapshot.alerts.isEmpty {
                    Text("No warnings or errors recorded.").foregroundColor(.secondary)
                }
                ForEach(Array(snapshot.alerts.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry["level"] as? String ?? "") · \(entry["category"] as? String ?? "")")
                            .font(.caption).foregroundColor(.orange)
                        Text(entry["message"] as? String ?? "").font(.system(.caption, design: .monospaced))
                    }
                }
            } header: {
                Text("Recent warnings")
            }

            Section {
                Button {
                    exportReport()
                } label: {
                    Label("Export Inventory Report", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    cleaning = true
                } label: {
                    Label("Clean Installer Temp Files", systemImage: "trash")
                }
                Button {
                    LRRuntimeBridge.exportDesktopReport { url in
                        if let url { share = ExportItem(url: url) } else { failure = "No desktop report is available yet." }
                    }
                } label: {
                    Label("Export Desktop Report", systemImage: "rectangle.and.text.magnifyingglass")
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("The inventory report lists environments, storage, processes and recent failures as a Markdown file you can save or send.")
            }
        }
        .navigationTitle("System")
        .onAppear { snapshot.refresh() }
        .onReceive(tick) { _ in snapshot.refresh() }
        .sheet(item: $share) { ShareView(item: $0) }
        .fullScreenCover(isPresented: $showTasks) {
            NativeController(controller: LinuxRunnerShell.makeTaskManagerController())
        }
        .confirmationDialog("Remove inactive installation staging files?", isPresented: $cleaning) {
            Button("Clean Temporary Files", role: .destructive) {
                if !UserDefaults.standard.bool(forKey: "InstallerActive") {
                    try? FileManager.default.removeItem(at: LRRuntimeBridge.managedStorageURL().appendingPathComponent("installer-temporary"))
                }
                snapshot.refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("System", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var environmentName: String {
        let root = LRRuntimeBridge.activeRootName()
        return manager.environments.first { $0.rootfsName == root }?.name ?? root
    }

    private var backend: String {
        let status = LRRuntimeBridge.executionBackendStatus()
        return status["active"] as? String ?? LRRuntimeBridge.executionMode()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func exportReport() {
        let text = InventoryReport.build(manager: manager, tasks: snapshot.tasks, health: snapshot.health, alerts: snapshot.alerts, free: snapshot.free)
        do {
            share = ExportItem(url: try InventoryReport.write(text))
        } catch {
            failure = error.localizedDescription
        }
    }
}

@MainActor enum InventoryReport {
    /// Written under the app's temporary directory: the share sheet's cleanup
    /// removes it afterwards, so reports never accumulate in the container.
    static func write(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("LinuxRunner-Inventory-\(stamp).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func build(manager: EnvironmentManager, tasks: [[String: Any]], health: [String: Any], alerts: [[String: Any]], free: Int64?) -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["LinuxRunnerSourceCommit"] as? String ?? "unknown"

        lines.append("# LinuxRunner inventory")
        lines.append("")
        lines.append("- Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("- App: \(version) (\(build)) · source \(commit)")
        lines.append("- Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        lines.append("- Runtime: \(LRRuntimeBridge.isRunning() ? "running" : "stopped") · \(LRRuntimeBridge.runtimeStatus())")
        lines.append("- Backend: \(LRRuntimeBridge.executionBackendStatus()["active"] as? String ?? LRRuntimeBridge.executionMode())")
        if let free = free {
            lines.append("- Free storage: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        lines.append("")

        if !health.isEmpty {
            lines.append("## Health")
            lines.append("")
            for key in health.keys.sorted() {
                lines.append("- \(key): \(String(describing: health[key] ?? "unavailable"))")
            }
            lines.append("")
        }

        if !manager.environments.isEmpty {
            lines.append("## Environments")
            lines.append("")
            lines.append("| Name | Distribution | Version | State | Storage | Last boot |")
            lines.append("| --- | --- | --- | --- | --- | --- |")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            for environment in manager.environments {
                let state = manager.active(environment) ? "active" : (environment.installationState ?? "installed")
                let boot = environment.lastBootedAt.map { formatter.string(from: $0) } ?? "—"
                lines.append("| \(environment.name) | \(environment.distribution) | \(environment.rootfsVersion) | \(state) | \(manager.size(environment)) | \(boot) |")
            }
            lines.append("")
        }

        if !tasks.isEmpty {
            lines.append("## Guest processes (\(tasks.count))")
            lines.append("")
            lines.append("| PID | PPID | State | Threads | Private | Shared | Name |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- |")
            let sorted = tasks.sorted { ($0["anonymous_kb"] as? Int ?? 0) > ($1["anonymous_kb"] as? Int ?? 0) }.prefix(30)
            for task in sorted {
                let privateKB = task["anonymous_kb"] as? Int ?? 0
                let sharedKB = task["shared_kb"] as? Int ?? 0
                lines.append("| \(task["pid"] as? Int ?? 0) | \(task["ppid"] as? Int ?? 0) | \(task["state"] as? String ?? "?") | \(task["threads"] as? Int ?? 0) | \(privateKB / 1024) MB | \(sharedKB / 1024) MB | \(task["name"] as? String ?? "?") |")
            }
            lines.append("")
        }

        if !alerts.isEmpty {
            lines.append("## Recent warnings")
            lines.append("")
            for entry in alerts {
                lines.append("- \(entry["level"] as? String ?? "") · \(entry["category"] as? String ?? "") · \(entry["message"] as? String ?? "")")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("Generated locally by LinuxRunner. No data leaves the device.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Startup command

/// Boot command editor for the Terminal settings form. The value is the argv
/// array the runtime uses for the boot shell; a native field is enough here
/// because the guest never parses it.
struct StartupCommandSection: View {
    private let prefs = UserPreferences.shared()
    @State private var boot = ""
    @State private var launch = ""

    private func tokens(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        Section {
            TextField("/bin/sh", text: $boot)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Login shell", text: $launch)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Button("Save") {
                    prefs.bootCommand = tokens(boot)
                    prefs.launchCommand = tokens(launch)
                }.disabled(tokens(boot).isEmpty && tokens(launch).isEmpty)
                Spacer()
                Button("Use Defaults", role: .destructive) {
                    prefs.bootCommand = ["/bin/sh"]
                    prefs.launchCommand = []
                    load()
                }
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Boot command runs when the environment starts; the login shell is what a new terminal opens. One argument per space-separated word. Leave the login shell empty to use the distribution default.")
        }
        .onAppear(perform: load)
    }

    private func load() {
        boot = (prefs.bootCommand as? [String] ?? []).joined(separator: " ")
        launch = (prefs.launchCommand as? [String] ?? []).joined(separator: " ")
    }
}
