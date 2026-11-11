import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Importing a root filesystem
//
// The runtime already imports archives safely: it copies the selection to
// private storage, verifies the SHA-256 of those exact bytes, then streams the
// tar through fakefsify (tar, tar.gz, tar.xz; entry budgets, no traversal, no
// absolute paths). What was missing was a native path for a user-supplied
// archive, so this screen validates the shape, imports, then records the
// environment in the catalog.

/// Not actor-isolated: read from the importer, the detached copy and the view.
enum RootfsImportLimits {
    /// 512 MiB is the bridge's own ceiling for an imported archive; checking it
    /// here turns a late failure into an immediate explanation.
    static let maximumBytes: Int64 = 512 * 1024 * 1024
    static let acceptedExtensions = ["tar.gz", "tgz", "tar.xz", "txz", "tar"]
}

struct RootfsImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let bytes: Int64
    let sha256: String
}

@MainActor final class RootfsImporter: ObservableObject {
    enum Phase: Equatable { case idle, preparing, importing, retrying, done, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fraction = 0.0
    @Published private(set) var message = ""
    @Published private(set) var failure: String?

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Throttle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1
        func shouldReport(_ fraction: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let bucket = Int(fraction * 100)
            guard bucket != last else { return false }
            last = bucket
            return true
        }
    }

    private var cancelled = Flag()
    private var task: Task<Void, Never>?

    var running: Bool { phase == .preparing || phase == .importing || phase == .retrying }

    func cancel() {
        cancelled.set()
        message = "Cancelling…"
    }

    func reset() {
        phase = .idle; fraction = 0; message = ""; failure = nil; cancelled = Flag()
    }

    /// Normalize a compound archive suffix once so the displayed name and
    /// import metadata cannot diverge (e.g. `foo.tar.gz` → `foo`).
    nonisolated static func defaultName(for filename: String) -> String {
        let lower = filename.lowercased()
        for suffix in [".tar.gz", ".tar.xz", ".tgz", ".txz", ".tar"] where lower.hasSuffix(suffix) {
            return String(filename.dropLast(suffix.count))
        }
        return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    static func looksAcceptable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return RootfsImportLimits.acceptedExtensions.contains { name.hasSuffix("." + $0) }
    }

    /// Synchronous copy + hash of the selection, so the sheet can show size and
    /// checksum before anything is written.
    nonisolated static func inspect(_ url: URL) throws -> RootfsImportRequest {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NSError(domain: "LinuxRunner.rootfs", code: 22, userInfo: [NSLocalizedDescriptionKey: "Choose a regular file, not a folder, link or package."])
        }
        let bytes = Int64(values.fileSize ?? 0)
        guard bytes > 0 else { throw NSError(domain: "LinuxRunner.rootfs", code: 22, userInfo: [NSLocalizedDescriptionKey: "The selected file is empty."]) }
        guard bytes <= RootfsImportLimits.maximumBytes else {
            throw NSError(domain: "LinuxRunner.rootfs", code: 27, userInfo: [NSLocalizedDescriptionKey: "That archive is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). An imported filesystem must be 512 MB or smaller; the importer unpacks it into the app container, which needs room for both."])
        }
        let sha = try DebianInstaller.sha256(url)
        return RootfsImportRequest(url: url, name: defaultName(for: url.lastPathComponent), bytes: bytes, sha256: sha)
    }

    func start(request: RootfsImportRequest, displayName: String, topLevel: String, manager: EnvironmentManager) {
        guard !running else { return }
        cancelled = Flag()
        failure = nil
        fraction = 0
        phase = .preparing
        message = "Preparing"
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { [weak self] in
            await self?.run(request: request, displayName: name.isEmpty ? request.name : name, topLevel: topLevel, manager: manager)
        }
    }

    private func run(request: RootfsImportRequest, displayName: String, topLevel: String, manager: EnvironmentManager) async {
        let root = UUID().uuidString.lowercased()
        let flag = cancelled
        let throttle = Throttle()
        let progress: (Double, String) -> Void = { [weak self] value, note in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor in
                guard let self, self.running else { return }
                self.fraction = min(max(value, 0), 1)
                if !note.isEmpty { self.message = note }
            }
        }

        phase = .importing
        message = "Copying and unpacking \(request.url.lastPathComponent)"

        // The bridge is synchronous and blocking; the security scope has to stay
        // open while it reads the picked file.
        let scoped = request.url.startAccessingSecurityScopedResource()
        let first = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            defer { if scoped { request.url.stopAccessingSecurityScopedResource() } }
            var metadata = Self.baseMetadata(name: request.name, topLevel: topLevel)
            metadata["archiveSHA256"] = request.sha256
            do {
                if topLevel.isEmpty {
                    try LRRuntimeBridge.importVerifiedEnvironment(request.url, root: root, sha256: request.sha256,
                                                                  metadata: metadata, progress: progress, cancel: { flag.isSet })
                } else {
                    try LRRuntimeBridge.importVerifiedEnvironment(request.url, root: root, sha256: request.sha256, topLevel: topLevel,
                                                                  metadata: metadata, progress: progress, cancel: { flag.isSet })
                }
                return .success(())
            } catch { return .failure(error) }
        }.value

        if flag.isSet {
            let cleanup = await Self.deleteRoot(root)
            phase = .failed
            failure = cleanup.map { "Import was cancelled, but the partial filesystem could not be removed: \($0). Remove the leftover from Settings › Storage." }
            message = ""
            return
        }
        switch first {
        case .failure(let error):
            phase = .failed
            failure = error.localizedDescription
            message = ""
            return
        case .success:
            break
        }

        // A tarball that wraps everything in one directory lands as /<wrapper>.
        // Detect that, remove the attempt and re-import with the wrapper
        // stripped, so the environment is usable without the user repacking.
        if let wrapper = Self.wrapperDirectory(root: root) {
            if flag.isSet {
                let cleanup = await Self.deleteRoot(root)
                phase = .failed
                failure = cleanup.map { "Import was cancelled, but the unpacked filesystem could not be removed: \($0). Remove the leftover from Settings › Storage." }
                message = ""
                return
            }
            phase = .retrying
            message = "Archive contains a single top-level folder; re-importing without it"
            if let cleanup = await Self.deleteRoot(root) {
                phase = .failed
                failure = "Could not remove the first unpacked attempt (root \(root)); automatic re-import was stopped: \(cleanup). Remove the leftover from Settings › Storage."
                return
            }
            if flag.isSet {
                phase = .failed
                failure = nil
                message = ""
                return
            }
            let retryRoot = UUID().uuidString.lowercased()
            var metadata = Self.baseMetadata(name: request.name, topLevel: wrapper)
            metadata["archiveSHA256"] = request.sha256
            let scopedRetry = request.url.startAccessingSecurityScopedResource()
            let retried = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                defer { if scopedRetry { request.url.stopAccessingSecurityScopedResource() } }
                do {
                    try LRRuntimeBridge.importVerifiedEnvironment(request.url, root: retryRoot, sha256: request.sha256, topLevel: wrapper,
                                                                  metadata: metadata, progress: progress, cancel: { flag.isSet })
                    return .success(())
                } catch { return .failure(error) }
            }.value
            if flag.isSet {
                let cleanup = await Self.deleteRoot(retryRoot)
                phase = .failed
                failure = cleanup.map { "Import was cancelled, but the partial retry could not be removed: \($0). Remove the leftover from Settings › Storage." }
                message = ""
                return
            }
            if case .failure(let error) = retried {
                let cleanup = await Self.deleteRoot(retryRoot)
                phase = .failed
                failure = "The archive has a single top-level folder and could not be re-imported without it: \(error.localizedDescription)"
                if let cleanup { failure = (failure ?? "") + " The partial retry could not be removed: \(cleanup). Remove the leftover from Settings › Storage." }
                return
            }
            await finish(root: retryRoot, displayName: displayName, request: request, topLevel: wrapper, manager: manager)
            return
        }

        await finish(root: root, displayName: displayName, request: request, topLevel: topLevel, manager: manager)
    }

    private func finish(root: String, displayName: String, request: RootfsImportRequest, topLevel: String, manager: EnvironmentManager) async {
        guard Self.looksLikeRootfs(root: root) else {
            let cleanup = await Self.deleteRoot(root)
            phase = .failed
            failure = "That archive does not contain a Linux root filesystem: no /etc and no /bin after unpacking. Export a userspace tree (for example `tar -C /path/to/root -czf rootfs.tar.gz .`), not a disk image, ISO or kernel package."
            if let cleanup { failure = (failure ?? "") + " The unpacked files could not be removed: \(cleanup)" + " Delete it in Settings › Storage." }
            return
        }

        let detected = Self.detectDistribution(root: root)
        var environment = LinuxEnvironment(name: displayName, rootfsName: root)
        environment.distribution = detected.name ?? "Imported Linux"
        environment.distributionID = detected.id ?? "custom"
        environment.packageManager = detected.packageManager
        environment.defaultShell = detected.shell
        environment.rootfsVersion = detected.version ?? "imported"
        environment.installationState = "Imported from \(request.url.lastPathComponent); packages and desktop components are not configured"
        environment.diagnosticHistory = ["imported archive=\(request.url.lastPathComponent) bytes=\(request.bytes) sha256=\(request.sha256)"]

        // The importer already wrote its own copy of the metadata; keep that
        // record consistent with what the catalog now claims.
        var record = Self.baseMetadata(name: displayName, topLevel: topLevel)
        record["distributionID"] = environment.distributionID ?? "custom"
        record["distribution"] = environment.distribution
        record["version"] = environment.rootfsVersion
        record["defaultShell"] = environment.defaultShell ?? "/bin/sh"
        if let packageManager = environment.packageManager { record["packageManager"] = packageManager }
        record["archiveSHA256"] = request.sha256
        record["importedFrom"] = request.url.lastPathComponent
        let installationURL = LRRuntimeBridge.rootURL(root).appendingPathComponent("environment-install.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
            try data.write(to: installationURL, options: .atomic)
            try FileManager.default.createDirectory(at: LRRuntimeBridge.exchangeURL(root), withIntermediateDirectories: true)
        } catch {
            let cleanup = await Self.deleteRoot(root)
            phase = .failed
            failure = "The filesystem was unpacked, but its install metadata or exchange directory could not be finalized: \(error.localizedDescription)"
            if let cleanup { failure = (failure ?? "") + " Cleanup also failed: \(cleanup). Remove the leftover from Settings › Storage." }
            return
        }

        manager.environments.append(environment)
        do { try manager.persist() } catch {
            manager.environments.removeAll { $0.rootfsName == root }
            // The filesystem is valid but the catalog could not record it; do not
            // leave an unreachable multi-gigabyte directory behind.
            let cleanup = await Self.deleteRoot(root)
            phase = .failed
            failure = "The filesystem imported, but the environment catalog could not be saved: \(error.localizedDescription)"
            if let cleanup { failure = (failure ?? "") + " The unpacked files could not be removed: \(cleanup)" }
            return
        }
        manager.refresh()
        fraction = 1
        message = ""
        phase = .done
    }

    private nonisolated static func baseMetadata(name: String, topLevel: String) -> [String: String] {
        ["distributionID": "custom",
         "distribution": name,
         "version": "imported",
         "packageManager": "unknown",
         "defaultShell": "/bin/sh",
         "provenance": topLevel.isEmpty ? "imported rootfs archive" : "imported rootfs archive, top level \(topLevel)"]
    }

    /// Removes a rolled-back import. Returns a description when the directory
    /// could not be removed, so the caller can say so instead of leaving the
    /// user with an unexplained multi-gigabyte folder.
    private static func deleteRoot(_ root: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            LRRuntimeBridge.deleteEnvironment(root) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    private static func guestDirectory(_ root: String) -> URL? {
        let base = LRRuntimeBridge.rootURL(root)
        let data = base.appendingPathComponent("data")
        if FileManager.default.fileExists(atPath: data.path) { return data }
        return FileManager.default.fileExists(atPath: base.path) ? base : nil
    }

    static func looksLikeRootfs(root: String) -> Bool {
        guard let directory = guestDirectory(root) else { return false }
        let etc = directory.appendingPathComponent("etc")
        let bin = directory.appendingPathComponent("bin")
        var isDirectory: ObjCBool = false
        let hasEtc = FileManager.default.fileExists(atPath: etc.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let hasBin = FileManager.default.fileExists(atPath: bin.path) || FileManager.default.fileExists(atPath: directory.appendingPathComponent("usr/bin").path)
        return hasEtc && hasBin
    }

    /// Single directory that itself looks like a root filesystem, if any.
    static func wrapperDirectory(root: String) -> String? {
        guard let directory = guestDirectory(root), !looksLikeRootfs(root: root) else { return nil }
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        // Only infer a wrapper when it is the entire archive payload. If a
        // sibling file or another directory exists, passing topLevel would make
        // fakefs reject the archive instead of validating the original tree.
        guard children.count == 1, let only = children.first,
              (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let name = only.lastPathComponent
        // fakefsify strips a literal prefix; a name with a slash or a dot segment
        // would either fail or escape the intended subtree.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: only.appendingPathComponent("etc").path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return name
    }

    struct Detected {
        var id: String?
        var name: String?
        var version: String?
        var packageManager: String?
        var shell: String?
    }

    static func detectDistribution(root: String) -> Detected {
        var detected = Detected()
        if let url = GuestPath.host(root: root, guest: "/etc/os-release"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            var fields: [String: String] = [:]
            for line in text.components(separatedBy: .newlines) {
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator])
                var value = String(line[line.index(after: separator)...])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                fields[key] = value
            }
            detected.id = fields["ID"].map { $0.lowercased() }
            detected.name = fields["PRETTY_NAME"] ?? fields["NAME"]
            detected.version = fields["VERSION_ID"] ?? fields["VERSION"]
        }
        switch (detected.id ?? "") {
        case "debian", "ubuntu", "kali", "raspbian": detected.packageManager = "apt"
        case "arch", "archarm": detected.packageManager = "pacman"
        case "fedora", "rhel", "centos", "rocky", "almalinux": detected.packageManager = "dnf"
        case "alpine": detected.packageManager = "apk"
        default: break
        }
        if detected.packageManager == nil {
            // Fall back to what the image actually ships, in case os-release is
            // missing or reports a derivative name.
            let probes: [(String, String)] = [("usr/bin/apt-get", "apt"), ("usr/bin/pacman", "pacman"), ("usr/bin/dnf", "dnf"), ("sbin/apk", "apk")]
            for probe in probes where GuestPath.host(root: root, guest: "/" + probe.0) != nil {
                detected.packageManager = probe.1
                break
            }
        }
        if detected.shell == nil {
            let shells = ["/bin/bash", "/bin/sh", "/usr/bin/bash", "/bin/ash"]
            detected.shell = shells.first { GuestPath.host(root: root, guest: $0) != nil }
        }
        if detected.name == nil, let id = detected.id { detected.name = id.capitalized }
        return detected
    }
}

// MARK: - Import screen

struct ImportRootfsView: View {
    @ObservedObject var manager: EnvironmentManager
    @StateObject private var importer = RootfsImporter()
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var inspecting = false
    @State private var picked: RootfsImportRequest?
    @State private var name = ""
    @State private var topLevel = ""
    @State private var problem: String?
    @State private var confirmed = false
    @State private var imported: String?

    private var canImport: Bool {
        picked != nil && !inspecting && !importer.running && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var alertTitle: String {
        if importer.phase == .failed && importer.failure != nil { return "Import failed" }
        if imported != nil { return "Environment imported" }
        return "Import Rootfs"
    }
    private var alertMessage: String {
        if importer.phase == .failed, let failure = importer.failure { return failure }
        if imported != nil { return "\(name) was added. Select it in Distributions to start it at the next launch." }
        return problem ?? ""
    }
    private var showingAlert: Bool { problem != nil || importer.phase == .failed && importer.failure != nil || imported != nil }

    var body: some View {
        Form {
            Section {
                Button {
                    picking = true
                } label: {
                    Label(picked == nil ? "Choose Archive…" : "Choose a Different Archive…", systemImage: "doc.badge.plus")
                }
                .disabled(importer.running)

                if inspecting {
                    HStack(spacing: 10) { ProgressView(); Text("Reading the archive…") }
                }
                if let picked {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(picked.url.lastPathComponent).font(.system(.body, design: .monospaced))
                        Text(ByteCountFormatter.string(fromByteCount: picked.bytes, countStyle: .file))
                            .font(.caption).foregroundColor(.secondary)
                        Text("SHA-256 \(picked.sha256.prefix(32))…")
                            .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Root filesystem")
            } footer: {
                Text("A tar archive of an ARM64 Linux userspace: .tar, .tar.gz, .tar.xz, up to 512 MB compressed. Expanded regular files are capped at 4 GiB and the archive at 500,000 entries. Not a disk image, ISO or kernel.")
            }

            Section {
                TextField("Environment name", text: $name)
                    .autocorrectionDisabled()
                    .disabled(importer.running)
            } footer: {
                Text("Shown in Distributions and Settings. The distribution name, version and package manager are read from /etc/os-release after unpacking.")
            }

            Section {
                TextField("Top-level folder (optional)", text: $topLevel)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(importer.running)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Leave empty for an archive whose entries start at ./bin, ./etc. If the archive wraps everything in one folder, it is detected and stripped automatically; name it here to skip that second pass.")
            }

            if importer.running {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: importer.fraction)
                        HStack {
                            Text(importer.message).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(importer.fraction * 100))%").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button("Cancel Import", role: .destructive) { importer.cancel() }
                }
            }

            Section {
                Button {
                    confirmed = true
                } label: {
                    Label("Import Environment", systemImage: "square.and.arrow.down")
                }
                .disabled(!canImport)
            } footer: {
                Text("The archive is verified by SHA-256 as it is copied, then unpacked into a new environment. Existing environments are untouched and the new one starts only after you select it and reopen LinuxRunner.")
            }
        }
        .navigationTitle("Import Rootfs")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error):
                problem = error.localizedDescription
            case .success(let urls):
                guard let url = urls.first else { return }
                guard RootfsImporter.looksAcceptable(url) else {
                    problem = "Choose a .tar, .tar.gz, .tgz, .tar.xz or .txz archive. Other formats are not unpacked by the importer."
                    return
                }
                inspecting = true
                Task.detached(priority: .userInitiated) {
                    let outcome = Result { try RootfsImporter.inspect(url) }
                    await MainActor.run {
                        inspecting = false
                        switch outcome {
                        case .success(let request):
                            picked = request
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = request.name
                            }
                        case .failure(let error):
                            problem = error.localizedDescription
                        }
                    }
                }
            }
        }
        .confirmationDialog("Import this filesystem as a new environment?", isPresented: $confirmed, titleVisibility: .visible) {
            Button("Import") {
                if let picked { importer.start(request: picked, displayName: name, topLevel: topLevel.trimmingCharacters(in: .whitespaces), manager: manager) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(name) · \(ByteCountFormatter.string(fromByteCount: picked?.bytes ?? 0, countStyle: .file))")
        }
        .onChange(of: importer.phase) { phase in
            if phase == .done { imported = name; }
        }
        .alert(alertTitle, isPresented: Binding(get: { showingAlert }, set: { visible in
            if !visible { problem = nil; imported = nil; if importer.phase == .failed { importer.reset() } }
        })) {
            Button(imported == nil ? "OK" : "Done") {
                let succeeded = imported != nil
                problem = nil; imported = nil
                if importer.phase == .failed { importer.reset() }
                if succeeded { dismiss() }
            }
        } message: {
            Text(alertMessage)
        }
    }
}
