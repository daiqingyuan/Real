import AppKit
import Foundation

/// The on-disk preference remains a comma/whitespace-separated list. Reading a
/// list never normalizes it or removes identifiers that are not installed.
enum ApplicationExclusions {
    static func identifiers(in value: String) -> [String] {
        var seen = Set<String>()
        return value.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init).filter { seen.insert($0).inserted }
    }

    static func updating(_ value: String, identifier: String, excluded: Bool) -> String {
        guard !identifier.isEmpty,
              !identifier.contains(where: { $0 == "," || $0.isWhitespace }) else { return value }
        var identifiers = identifiers(in: value)
        // A no-op preserves the original spelling/format, including old values.
        guard identifiers.contains(identifier) != excluded else { return value }
        if excluded { identifiers.append(identifier) }
        else { identifiers.removeAll { $0 == identifier } }
        return identifiers.joined(separator: ", ")
    }

    static func applications(_ installed: [CatalogApplication], preserving value: String) -> [CatalogApplication] {
        var known = Set<String>()
        var records = installed.filter { known.insert($0.id).inserted }
        let selected = Set(identifiers(in: value))
        for identifier in identifiers(in: value) where known.insert(identifier).inserted {
            records.append(CatalogApplication(bundleIdentifier: identifier, name: identifier, url: nil, isRunning: false))
        }
        return records.sorted {
            if selected.contains($0.id) != selected.contains($1.id) { return selected.contains($0.id) }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

struct CatalogApplication: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL?
    let isRunning: Bool
    var id: String { bundleIdentifier }
}

struct ApplicationCatalogSnapshot: Sendable {
    var applications: [CatalogApplication] = []
    var failedPaths: [String] = []
    var truncated = false
    var cancelled = false
    var directoriesVisited = 0
    var entriesVisited = 0
}

struct ApplicationCatalogScanLimits: Sendable {
    var maximumDepth = 4
    var maximumDirectories = 1_500
    var maximumEntries = 20_000
    var maximumApplications = 2_000
    var maximumInfoBytes = 1_048_576
}

/// Only scans explicit application roots. It does not use Launch Services to
/// open apps, traverse the home directory, follow directory symlinks, or enter
/// an app package (even an invalid app package).
enum ApplicationCatalogScanner {
    static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
    }

    static func scan(roots: [URL] = defaultRoots, runningApplications: [URL] = [],
                     limits: ApplicationCatalogScanLimits = ApplicationCatalogScanLimits(),
                     cancelled: () -> Bool = { false },
                     directoryContents: ((URL) throws -> [URL])? = nil) -> ApplicationCatalogSnapshot {
        var result = ApplicationCatalogSnapshot()
        guard limits.maximumDepth >= 0, limits.maximumDirectories > 0,
              limits.maximumEntries > 0, limits.maximumApplications > 0,
              limits.maximumInfoBytes > 0 else { result.truncated = true; return result }
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        var applications: [String: CatalogApplication] = [:]
        var seenApps = Set<String>()
        var seenDirectories = Set<String>()
        var seenFailures = Set<String>()

        func fail(_ url: URL) {
            // Bound diagnostic metadata as well as traversal. It is only used
            // to explain an incomplete list, never to rewrite exclusions.
            if result.failedPaths.count < 32, seenFailures.insert(url.path).inserted { result.failedPaths.append(url.path) }
        }
        func isRetired(_ url: URL) -> Bool {
            url.pathComponents.contains { component in
                let lower = component.lowercased()
                return lower.hasSuffix(".disabled") || lower.contains(".app.disabled")
            }
        }
        func shouldStop() -> Bool {
            if cancelled() { result.cancelled = true; return true }
            if result.entriesVisited >= limits.maximumEntries || applications.count >= limits.maximumApplications {
                result.truncated = true; return true
            }
            return false
        }
        func readApp(_ candidate: URL, running: Bool) {
            let url = candidate.standardizedFileURL
            guard url.isFileURL, !isRetired(url), url.pathExtension.lowercased() == "app",
                  !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
                  seenApps.insert(url.path).inserted else { return }
            do {
                let properties = try url.resourceValues(forKeys: keys)
                guard properties.isDirectory == true, properties.isSymbolicLink != true,
                      properties.isHidden != true else { return }
                let contents = try url.appendingPathComponent("Contents", isDirectory: true).resourceValues(forKeys: keys)
                guard contents.isDirectory == true, contents.isSymbolicLink != true else { fail(url); return }
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                let info = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let size = info.fileSize, size > 0, size <= limits.maximumInfoBytes else { fail(infoURL); return }
                let data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
                guard data.count <= limits.maximumInfoBytes,
                      let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let identifier = values["CFBundleIdentifier"] as? String,
                      !identifier.isEmpty, identifier.count <= 512,
                      !identifier.contains(where: { $0 == "," || $0.isWhitespace }) else { fail(infoURL); return }
                // Running paths were processed first; then roots are processed
                // in order, so a backup or duplicate cannot replace that app.
                guard applications[identifier] == nil else { return }
                let rawName = (values["CFBundleDisplayName"] as? String) ?? (values["CFBundleName"] as? String)
                let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = url.deletingPathExtension().lastPathComponent
                applications[identifier] = CatalogApplication(bundleIdentifier: identifier,
                    name: String((name?.isEmpty == false ? name! : fallback).prefix(256)), url: url, isRunning: running)
            } catch {
                // Invalid application folders are skipped but reported. A
                // failed directory or app never removes a saved identifier.
                fail(url)
            }
        }

        for candidate in runningApplications.sorted(by: { $0.path < $1.path }) {
            if shouldStop() { break }
            result.entriesVisited += 1
            readApp(candidate, running: true)
        }
        for root in roots {
            if shouldStop() { break }
            var pending: [(URL, Int)] = [(root.standardizedFileURL, 0)]
            var cursor = 0
            while cursor < pending.count {
                if shouldStop() { break }
                let (directory, depth) = pending[cursor]; cursor += 1
                guard directory.isFileURL, !isRetired(directory), seenDirectories.insert(directory.path).inserted else { continue }
                do {
                    let properties = try directory.resourceValues(forKeys: keys)
                    guard properties.isDirectory == true, properties.isSymbolicLink != true,
                          properties.isHidden != true else { continue }
                    if directory.pathExtension.lowercased() == "app" {
                        result.entriesVisited += 1; readApp(directory, running: false); continue
                    }
                    guard result.directoriesVisited < limits.maximumDirectories else { result.truncated = true; break }
                    result.directoriesVisited += 1
                    let children = try directoryContents?(directory) ?? fileManager.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                    for child in children.sorted(by: { $0.path < $1.path }) {
                        if shouldStop() { break }
                        result.entriesVisited += 1
                        let url = child.standardizedFileURL
                        // A dependency supplying directory entries is used by
                        // fixtures. Treat it as untrusted, just like disk data.
                        guard url.isFileURL, url.deletingLastPathComponent().path == directory.path,
                              !isRetired(url), !url.lastPathComponent.hasPrefix(".") else { continue }
                        let childProperties: URLResourceValues
                        do { childProperties = try url.resourceValues(forKeys: keys) }
                        catch { fail(url); continue }
                        guard childProperties.isDirectory == true, childProperties.isSymbolicLink != true else { continue }
                        if url.pathExtension.lowercased() == "app" { readApp(url, running: false) }
                        else if depth < limits.maximumDepth { pending.append((url, depth + 1)) }
                        else { result.truncated = true }
                    }
                } catch {
                    if !((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError) { fail(directory) }
                }
            }
        }
        result.applications = applications.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        return result
    }
}

@MainActor
final class ApplicationCatalogModel: ObservableObject {
    @Published private(set) var snapshot = ApplicationCatalogSnapshot()
    @Published private(set) var isScanning = false
    private var worker: Task<ApplicationCatalogSnapshot, Never>?
    private var delivery: Task<Void, Never>?
    private var generation = UUID()

    func refresh() {
        cancel()
        let request = UUID(); generation = request
        // Background system agents have no Dock windows to exclude. Installed
        // accessory apps remain discoverable through the application roots.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        isScanning = true
        let task = Task.detached(priority: .utility) {
            ApplicationCatalogScanner.scan(runningApplications: running,
                cancelled: { Task<Never, Never>.isCancelled })
        }
        worker = task
        delivery = Task { [weak self] in
            let result = await task.value
            guard !Task.isCancelled, let self, self.generation == request, !result.cancelled else { return }
            self.snapshot = result
            self.isScanning = false
            self.worker = nil
            self.delivery = nil
        }
    }

    func cancel() {
        generation = UUID()
        worker?.cancel(); worker = nil
        delivery?.cancel(); delivery = nil
        isScanning = false
    }
}
