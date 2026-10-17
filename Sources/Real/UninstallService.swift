import AppKit
import Combine
import SwiftUI

/// Removes only the bundle hosting this process. No globbing or shell deletion.
@MainActor struct UninstallTarget {
    static let identifier = "local.dan.real"
    let appURL: URL
    let homeURL: URL

    func validate(fileManager fm: FileManager = .default) throws {
        let app = appURL.standardizedFileURL
        guard app.isFileURL, app.pathExtension == "app", app.pathComponents.count > 2,
              app.resolvingSymlinksInPath() == app,
              let bundle = Bundle(url: app), bundle.bundleIdentifier == Self.identifier,
              let executable = bundle.executableURL,
              executable.standardizedFileURL.path.hasPrefix(app.path + "/Contents/MacOS/"),
              executable.resolvingSymlinksInPath() == executable.standardizedFileURL,
              fm.isExecutableFile(atPath: executable.path) else {
            throw UninstallError.invalidTarget
        }
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
        guard values.isDirectory == true, values.volumeIsReadOnly != true,
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UninstallError.notWritable
        }
    }

    // These paths contain app metadata only. Shelf's bookmarked targets and
    // exported diagnostics deliberately never enter the removal list.
    var dataURLs: [URL] {
        ["Library/Application Support/Real", "Library/Caches/local.dan.real",
         "Library/Logs/real", "Library/Saved Application State/local.dan.real.savedState"]
            .map { homeURL.appendingPathComponent($0, isDirectory: true) }
    }

    func cleanData(fileManager fm: FileManager = .default,
                   trash: (URL) throws -> Void,
                   clearPreferences: () -> Void,
                   clearTokens: () throws -> Void) -> [String] {
        var failures: [String] = []
        for url in dataURLs {
            // Refuse symlinked data/parents rather than following them into
            // another folder. Missing paths are already clean.
            do { _ = try url.resourceValues(forKeys: [.isSymbolicLinkKey]) }
            catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { continue }
                if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { continue }
                failures.append(url.path); continue
            }
            guard url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL else {
                failures.append(url.path); continue
            }
            do { try trash(url) } catch { failures.append(url.path) }
        }
        clearPreferences()
        do { try clearTokens() } catch { failures.append(tr("播放器配对信息")) }
        return failures
    }
}

enum UninstallError: LocalizedError {
    case invalidTarget, notWritable
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "无法确认当前应用的位置，未移除任何文件。请在访达中手动移除 Real。"
        case .notWritable: return "当前应用所在位置不允许移除。请退出 Real 后，在访达中将它移到废纸篓。"
        }
    }
}

@MainActor final class UninstallService: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage = ""
    @Published var removeData = false
    let target: UninstallTarget
    private let unregister: () throws -> Void
    private let suspend: () -> Void
    private let resume: () -> Void
    private let trash: (URL) throws -> Void
    private let cleanData: () -> [String]
    private let finish: ([String]) -> Void

    init(target: UninstallTarget, unregister: @escaping () throws -> Void,
         suspend: @escaping () -> Void, resume: @escaping () -> Void,
         trash: @escaping (URL) throws -> Void,
         cleanData: @escaping () -> [String], finish: @escaping ([String]) -> Void) {
        self.target = target; self.unregister = unregister; self.suspend = suspend
        self.resume = resume; self.trash = trash; self.cleanData = cleanData; self.finish = finish
    }
    func present() { guard !isWorking else { return }; removeData = false; errorMessage = ""; isPresented = true }
    func dismiss() { guard !isWorking else { return }; isPresented = false }
    func confirm() {
        // Opening/cancelling the dialog cannot mutate the application or data.
        guard isPresented, !isWorking else { return }
        isWorking = true; errorMessage = ""
        var suspended = false
        do {
            try target.validate()
            try unregister() // Also unregister pending approval before removal.
            suspend(); suspended = true
            try trash(target.appURL)
        } catch {
            if suspended { resume() }
            errorMessage = tr("未完成卸载") + "\n" + (error is UninstallError ? tr(error.localizedDescription) : error.localizedDescription)
            if suspended { errorMessage += "\n" + tr("后台功能已恢复；登录时启动已关闭，如有需要请重新开启。") }
            isWorking = false
            return
        }
        // No preferences, files or credentials are touched if app removal fails.
        let failures = removeData ? cleanData() : []
        finish(failures)
    }
}

struct UninstallView: View {
    @ObservedObject var service: UninstallService
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(tr("卸载 Real"), systemImage: "trash").font(.title2.bold())
            Text(tr("确认后将关闭登录时启动、停止后台，并将当前这份 Real 移到废纸篓。"))
            Text(service.target.appURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Toggle(tr("同时移除设置、缓存和播放器配对信息"), isOn: $service.removeData)
            Text(tr("清理会影响这台电脑上使用同一身份的 Real 副本；暂存架只移除文件引用，原文件、导出的诊断和备份都会保留。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(tr("macOS 的隐私权限记录可能仍留在系统设置中。"))
                .font(.caption).foregroundStyle(.secondary)
            if !service.errorMessage.isEmpty {
                Text(service.errorMessage).foregroundStyle(.red).textSelection(.enabled)
                Button(tr("在访达中显示 Real")) { NSWorkspace.shared.activateFileViewerSelecting([service.target.appURL]) }
            }
            HStack {
                if service.isWorking { ProgressView().controlSize(.small); Text(tr("正在卸载…")) }
                Spacer()
                Button(tr("取消")) { service.dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("卸载并退出"), role: .destructive) { service.confirm() }
            }
        }.padding(28).frame(width: 490).disabled(service.isWorking)
            .interactiveDismissDisabled(service.isWorking)
    }
}
