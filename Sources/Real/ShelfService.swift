import AppKit
import Combine
import Foundation
import QuickLookUI

struct ShelfFile: Identifiable {
    let id: UUID
    let url: URL
    var name: String { url.lastPathComponent }
}

@MainActor
final class ShelfService: ObservableObject {
    @Published private(set) var items: [ShelfFile] = []
    @Published private(set) var status = ""

    private struct SavedFile: Codable {
        let id: UUID
        var bookmark: Data
    }
    private var saved: [SavedFile] = []
    private let storageURL: URL
    private var preserveUnreadableStorage = false
    private var sharing: [UUID: ShelfShareSession] = [:]
    private var previews: [UUID: ShelfPreviewSession] = [:]

    init(storageURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.storageURL = storageURL ?? support.appendingPathComponent("Real", isDirectory: true).appendingPathComponent("shelf-bookmarks.json")
        restore()
    }

    func add(urls: [URL]) {
        var errors: [String] = []
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            guard !items.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard try url.checkResourceIsReachable() else { continue }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let id = UUID()
                saved.append(SavedFile(id: id, bookmark: bookmark))
                items.append(ShelfFile(id: id, url: url))
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        status = errors.joined(separator: "\n")
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        saved.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        saved.removeAll()
        persist()
    }

    func reveal(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let accessed = item.url.startAccessingSecurityScopedResource()
        defer { if accessed { item.url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            status = tr("此文件已不可用：") + item.name; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let url = item.url
        let accessed = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path),
              let application = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            status = tr("文件不可用，或没有可打开它的应用。")
            return
        }
        // Keep our access until Launch Services completes the handoff. The opened
        // application manages its own document access after that handoff.
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            if accessed { url.stopAccessingSecurityScopedResource() }
            Task { @MainActor in
                if let error { self?.status = tr("无法打开文件：") + error.localizedDescription }
            }
        }
    }

    func preview(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let existing = previews[id] { existing.showWindow(nil); return }
        let accessed = item.url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            if accessed { item.url.stopAccessingSecurityScopedResource() }
            status = tr("此文件已不可用：") + item.name; return
        }
        let session = ShelfPreviewSession(url: item.url, accessing: accessed) { [weak self] in
            self?.previews.removeValue(forKey: id)
        }
        previews[id] = session
        session.showWindow(nil)
    }

    func share(id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }) ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let view = window.contentView else {
            status = tr("请打开文件暂存窗口后分享文件。"); return
        }
        let token = UUID()
        let session = ShelfShareSession(url: item.url) { [weak self] error in
            self?.sharing.removeValue(forKey: token)
            if let error { self?.status = error }
        }
        sharing[token] = session
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = view.bounds.contains(point) ? point : NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        session.show(in: view, at: anchor)
    }

    private func restore() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let records = try JSONDecoder().decode([SavedFile].self, from: Data(contentsOf: storageURL))
            var unavailable = 0
            var seenIDs = Set<UUID>()
            for var record in records where seenIDs.insert(record.id).inserted {
                // Retain unresolved bookmarks as well. Adding another file must
                // not delete a reference merely because its volume is offline.
                defer { saved.append(record) }
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard try url.checkResourceIsReachable() else { unavailable += 1; continue }
                    if stale {
                        record.bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                              includingResourceValuesForKeys: nil, relativeTo: nil)
                    }
                    items.append(ShelfFile(id: record.id, url: url))
                } catch { unavailable += 1 }
            }
            // Unavailable records remain in the saved collection across edits;
            // they can resolve again after their volume is reconnected.
            if unavailable > 0 { status = String(format: tr("%ld 个暂存文件当前不可用。"), unavailable) }
        } catch {
            preserveUnreadableStorage = true
            status = tr("无法读取已保存的文件暂存：") + error.localizedDescription
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if preserveUnreadableStorage {
                // Never replace the only copy of an unreadable bookmark store.
                // If preserving it fails, leave it untouched and report the error.
                let recovery = storageURL.deletingPathExtension().appendingPathExtension("recovery-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: storageURL, to: recovery)
                preserveUnreadableStorage = false
            }
            try JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
        } catch { status = tr("无法保存文件暂存：") + error.localizedDescription }
    }
}

/// A dedicated Quick Look view avoids taking over the application's shared
/// preview-panel responder chain. Access lasts for the whole preview window.
@MainActor
private final class ShelfPreviewSession: NSWindowController, NSWindowDelegate {
    private let url: URL
    private var accessing: Bool
    private let completion: () -> Void
    private let previewView: QLPreviewView

    init(url: URL, accessing: Bool, completion: @escaping () -> Void) {
        self.url = url
        self.accessing = accessing
        self.completion = completion
        let bounds = NSRect(x: 0, y: 0, width: 760, height: 560)
        previewView = QLPreviewView(frame: bounds, style: .normal)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = previewView
        window.center()
        previewView.autostarts = false
        previewView.shouldCloseWithWindow = false
        previewView.previewItem = url as NSURL
    }

    required init?(coder: NSCoder) { fatalError("Use init(url:accessing:completion:)") }

    func windowWillClose(_ notification: Notification) {
        previewView.close()
        if accessing { url.stopAccessingSecurityScopedResource(); accessing = false }
        completion()
    }

    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

/// Keeps security-scoped access alive until the selected sharing service finishes.
@MainActor
private final class ShelfShareSession: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let url: URL
    private let completion: (String?) -> Void
    private var picker: NSSharingServicePicker?
    private var accessing = false
    private var finished = false

    init(url: URL, completion: @escaping (String?) -> Void) {
        self.url = url
        self.completion = completion
    }

    func show(in view: NSView, at point: NSPoint) {
        accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path) else {
            finish(tr("此文件已不可用：") + url.lastPathComponent); return
        }
        let picker = NSSharingServicePicker(items: [url])
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { Task { @MainActor in self.finish(nil) } }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(nil) }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(tr("无法分享文件：") + error.localizedDescription)
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        if accessing { url.stopAccessingSecurityScopedResource(); accessing = false }
        completion(error)
    }

    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}
