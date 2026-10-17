import AppKit
import Combine
import Foundation
import CoreServices

private struct PlayerTarget {
    let pid: pid_t
    let name: String
    let bundleID: String
    let bundleURL: URL
}

private struct PlayerSnapshot {
    let target: PlayerTarget
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    var position = 0.0
    var duration = 0.0
    var artworkData: Data?
    var artworkURL: URL?
}

/// Reads only the installed player's public scripting dictionary, never executable source.
private final class PlayerDictionary: NSObject, XMLParserDelegate {
    var application: [String: String] = [:]
    var track: [String: String] = [:]
    var artwork: [String: String] = [:]
    var commands: [String: String] = [:]
    var classes: [String: String] = [:]
    var enumerators: [String: String] = [:]
    private var currentClass = ""

    init(bundleURL: URL) throws {
        super.init()
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        let urls = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        guard let url = urls.first(where: { $0.pathExtension == "sdef" }), let parser = XMLParser(contentsOf: url) else {
            throw NSError(domain: "real.Media", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取此播放器的脚本字典。"])
        }
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "real.Media", code: 2) }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = attributes["name"] ?? ""
        let code = attributes["code"] ?? ""
        if element == "class" || element == "class-extension" {
            currentClass = element == "class" ? name : (attributes["extends"] ?? "")
            if !code.isEmpty { classes[name] = code }
        } else if element == "property" {
            switch currentClass {
            case "application": application[name] = code
            case "track": track[name] = code
            case "artwork": artwork[name] = code
            default: break
            }
        } else if element == "command" { commands[name] = code }
        else if element == "enumerator" { enumerators[name] = code }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "class" || element == "class-extension" { currentClass = "" }
    }
}

private func eventCode(_ text: String) -> UInt32 {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Cancellation between sequential permission prompts; an already visible system prompt remains system-owned.
private final class MediaAuthorizationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

/// All methods run on one dedicated serial queue; no synchronous Apple Events on the UI thread.
private final class PlayerBridge: @unchecked Sendable {
    private var dictionaries: [String: PlayerDictionary] = [:]
    private var artCache: [String: Data] = [:]

    private func dictionary(_ target: PlayerTarget) throws -> PlayerDictionary {
        if let value = dictionaries[target.bundleID] { return value }
        let value = try PlayerDictionary(bundleURL: target.bundleURL)
        dictionaries[target.bundleID] = value
        return value
    }

    private func property(_ code: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: eventCode("prop")), forKeyword: eventCode("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: eventCode("prop")), forKeyword: eventCode("form"))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: eventCode(code)), forKeyword: eventCode("seld"))
        record.setDescriptor(container, forKeyword: eventCode("from"))
        return record.coerce(toDescriptorType: eventCode("obj "))!
    }

    private func firstArtwork(_ classCode: String, track: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: eventCode(classCode)), forKeyword: eventCode("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: eventCode("indx")), forKeyword: eventCode("form"))
        record.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: eventCode("seld"))
        record.setDescriptor(track, forKeyword: eventCode("from"))
        return record.coerce(toDescriptorType: eventCode("obj "))!
    }

    private func send(_ target: PlayerTarget, suite: String, event: String, object: NSAppleEventDescriptor? = nil, value: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let targetAddress = NSAppleEventDescriptor(processIdentifier: target.pid)
        guard let address = targetAddress.aeDesc else { throw NSError(domain: NSOSStatusErrorDomain, code: -1700) }
        // Polling and transport controls never trigger consent implicitly. The explicit UI action asks.
        let permission = AEDeterminePermissionToAutomateTarget(address, eventCode(suite), eventCode(event), false)
        guard permission == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(permission)) }
        let descriptor = NSAppleEventDescriptor(eventClass: eventCode(suite), eventID: eventCode(event), targetDescriptor: targetAddress, returnID: -1, transactionID: 0)
        if let object { descriptor.setParam(object, forKeyword: eventCode("----")) }
        if let value { descriptor.setParam(value, forKeyword: eventCode("data")) }
        let reply = try descriptor.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: eventCode("errn")), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value), userInfo: [NSLocalizedDescriptionKey: reply.paramDescriptor(forKeyword: eventCode("errs"))?.stringValue ?? "播放器请求失败。"])
        }
        return reply.paramDescriptor(forKeyword: eventCode("----")) ?? .null()
    }

    private func get(_ target: PlayerTarget, _ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send(target, suite: "core", event: "getd", object: object)
    }

    func read(_ target: PlayerTarget) throws -> PlayerSnapshot {
        let dictionary = try dictionary(target)
        guard let stateCode = dictionary.application["player state"], let trackCode = dictionary.application["current track"] else {
            throw NSError(domain: "real.Media", code: 3, userInfo: [NSLocalizedDescriptionKey: "此播放器未提供所需的播放接口。"])
        }
        let state = try get(target, property(stateCode))
        var snapshot = PlayerSnapshot(target: target)
        snapshot.playing = state.enumCodeValue == eventCode(dictionary.enumerators["playing"] ?? "kPSP")
        let track = property(trackCode)
        // A stopped app may have no current track. Permission errors above are not suppressed.
        do {
            snapshot.title = try get(target, property(dictionary.track["name"] ?? "pnam", of: track)).stringValue ?? ""
        } catch let error as NSError where error.code == -1728 || error.code == -1700 {
            return snapshot
        }
        if let code = dictionary.track["artist"] { snapshot.artist = try get(target, property(code, of: track)).stringValue ?? "" }
        if let code = dictionary.track["album"] { snapshot.album = try get(target, property(code, of: track)).stringValue ?? "" }
        if let code = dictionary.track["duration"] {
            snapshot.duration = try get(target, property(code, of: track)).doubleValue
            // Spotify's desktop scripting duration is milliseconds; playback position is seconds.
            if target.bundleID == "com.spotify.client" { snapshot.duration /= 1000 }
        }
        if let code = dictionary.application["player position"] { snapshot.position = try get(target, property(code)).doubleValue }
        snapshot.position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
        snapshot.duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        let artKey = "\(target.bundleID)\u{0}\(snapshot.artist)\u{0}\(snapshot.album)\u{0}\(snapshot.title)"
        if let data = artCache[artKey] { snapshot.artworkData = data }
        else if let code = dictionary.track["artwork url"] ?? dictionary.track["artwork URL"],
                let string = try? get(target, property(code, of: track)).stringValue,
                let url = URL(string: string), url.scheme == "https" {
            snapshot.artworkURL = url
        } else if let classCode = dictionary.classes["artwork"], let rawCode = dictionary.artwork["raw data"],
                  let descriptor = try? get(target, property(rawCode, of: firstArtwork(classCode, track: track))) {
            let data = descriptor.data
            if !data.isEmpty, data.count <= 8_000_000 {
                snapshot.artworkData = data
                if artCache.count >= 12 { artCache.removeAll() }
                artCache[artKey] = data
            }
        }
        return snapshot
    }

    func control(_ target: PlayerTarget, command: String, position: Double?) throws {
        let dictionary = try dictionary(target)
        if let position, let code = dictionary.application["player position"] {
            _ = try send(target, suite: "core", event: "setd", object: property(code), value: NSAppleEventDescriptor(double: position))
        } else if let code = dictionary.commands[command], code.utf8.count == 8 {
            _ = try send(target, suite: String(code.prefix(4)), event: String(code.suffix(4)))
        } else {
            throw NSError(domain: "real.Media", code: 4, userInfo: [NSLocalizedDescriptionKey: "此播放器不支持这项控制。"])
        }
    }
}

@MainActor
final class MediaService: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceName = ""
    var sourceBundleIdentifier: String? { selected?.bundleID }
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var authorizationStatus: String?

    private let queue = DispatchQueue(label: "real.media.appleevents", qos: .utility)
    private let bridge = PlayerBridge()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var busy = false
    private var denied: Set<pid_t> = []
    private var selected: PlayerTarget?
    private var generation = 0
    private var artworkTask: Task<Void, Never>?
    private var artworkKey = ""
    private var authorizationRequest: MediaAuthorizationRequest?
    private var actionLifetime = MediaAuthorizationRequest()

    init() {} // Constructing the service never asks for Automation access.

    func start() {
        guard !started else { return }
        started = true
        actionLifetime = MediaAuthorizationRequest()
        generation += 1
        denied.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshSchedule() }
            })
        }
        refreshSchedule()
    }

    func stop() {
        actionLifetime.cancel()
        authorizationRequest?.cancel()
        authorizationRequest = nil
        isRequestingAuthorization = false
        authorizationStatus = nil
        started = false
        generation += 1
        timer?.invalidate()
        timer = nil
        artworkTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        clearTrack()
        errorMessage = nil
    }

    deinit {
        actionLifetime.cancel(); authorizationRequest?.cancel()
        timer?.invalidate(); artworkTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Explicit user action only. The SDK requires this permission API to run off the main thread.
    /// Targets are current process IDs, so requesting permission cannot launch a player.
    func requestAuthorization() {
        guard !isRequestingAuthorization else { return }
        let targets = runningTargets()
        guard !targets.isEmpty else {
            errorMessage = tr("请先打开音乐或 Spotify，再允许播放器控制。")
            authorizationStatus = nil
            return
        }
        let request = MediaAuthorizationRequest()
        authorizationRequest = request
        isRequestingAuthorization = true
        authorizationStatus = tr("请在系统提示中允许播放器控制。")
        errorMessage = nil
        queue.async { [weak self] in
            var results: [(PlayerTarget, OSStatus)] = []
            for target in targets {
                guard request.isActive else { break }
                guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
                      app.bundleIdentifier == target.bundleID else {
                    results.append((target, OSStatus(procNotFound)))
                    continue
                }
                let descriptor = NSAppleEventDescriptor(processIdentifier: target.pid)
                guard let address = descriptor.aeDesc else { continue }
                let result = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, true)
                results.append((target, result))
            }
            Task { @MainActor [weak self] in
                guard let self, authorizationRequest === request, request.isActive else { return }
                authorizationRequest = nil
                isRequestingAuthorization = false
                var failures: [String] = []
                var granted: [String] = []
                for (target, result) in results {
                    if result == noErr {
                        denied.remove(target.pid)
                        granted.append(target.name)
                    } else {
                        if result == errAEEventNotPermitted || result == errAEEventWouldRequireUserConsent { denied.insert(target.pid) }
                        failures.append(describe(NSError(domain: NSOSStatusErrorDomain, code: Int(result)), player: target.name))
                    }
                }
                errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
                authorizationStatus = granted.isEmpty ? nil : String(format: tr("已允许控制：%@"), granted.joined(separator: ", "))
                if started { poll() }
            }
        }
    }

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }
    func seek(to value: Double) {
        guard value.isFinite, duration > 0 else { return }
        control("seek", position: min(duration, max(0, value)))
    }

    private func runningTargets() -> [PlayerTarget] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, ["com.apple.Music", "com.spotify.client"].contains(id),
                  !app.isTerminated, let url = app.bundleURL else { return nil }
            return PlayerTarget(pid: app.processIdentifier, name: id == "com.apple.Music" ? "Music" : "Spotify", bundleID: id, bundleURL: url)
        }
    }

    private func refreshSchedule() {
        guard started else { return }
        let targets = runningTargets()
        denied.formIntersection(Set(targets.map(\.pid)))
        if targets.isEmpty {
            generation += 1 // Discard any reply arriving after the last player exits.
            timer?.invalidate()
            timer = nil
            clearTrack()
            errorMessage = nil
        } else {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
            }
            poll()
        }
    }

    private func poll() {
        guard started, !busy else { return }
        let targets = runningTargets().filter { !denied.contains($0.pid) }
        guard !targets.isEmpty else { return }
        busy = true
        let requestGeneration = generation
        let preferred = selected?.pid
        queue.async { [bridge, weak self] in
            let results = targets.map { target -> (PlayerTarget, Result<PlayerSnapshot, Error>) in
                (target, Result { try bridge.read(target) })
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                busy = false
                guard started, generation == requestGeneration else { return }
                var snapshots: [PlayerSnapshot] = []
                var errors: [String] = []
                for (target, result) in results {
                    switch result {
                    case .success(let snapshot):
                        if runningTargets().contains(where: { $0.pid == target.pid }) { snapshots.append(snapshot) }
                    case .failure(let error):
                        if [-1743, -1744].contains((error as NSError).code) { denied.insert(target.pid) }
                        errors.append(describe(error, player: target.name))
                    }
                }
                errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                let snapshot = snapshots.first(where: { $0.playing && $0.target.pid == preferred })
                    ?? snapshots.first(where: \.playing)
                    ?? snapshots.first(where: { $0.target.pid == preferred && !$0.title.isEmpty })
                    ?? snapshots.first(where: { !$0.title.isEmpty })
                    ?? snapshots.first
                if let snapshot { apply(snapshot) } else { clearTrack() }
            }
        }
    }

    private func apply(_ snapshot: PlayerSnapshot) {
        selected = snapshot.target
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        isPlaying = snapshot.playing
        position = snapshot.position
        duration = snapshot.duration
        sourceName = snapshot.target.name
        let key = "\(snapshot.target.pid)\u{0}\(title)\u{0}\(artist)\u{0}\(album)"
        guard artworkKey != key else { return }
        artworkKey = key
        artworkTask?.cancel()
        artwork = snapshot.artworkData.flatMap(NSImage.init(data:))
        guard artwork == nil, let url = snapshot.artworkURL else { return }
        artworkTask = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let self, artworkKey == key,
                      (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000 else { return }
                artwork = NSImage(data: data)
            } catch { /* Artwork is optional and must not hide playback state. */ }
        }
    }

    private func clearTrack() {
        selected = nil
        title = ""
        artist = ""
        album = ""
        isPlaying = false
        position = 0
        duration = 0
        sourceName = ""
        artworkTask?.cancel()
        artworkKey = ""
        artwork = nil
    }

    private func control(_ command: String, position: Double? = nil) {
        guard started, let target = selected, runningTargets().contains(where: { $0.pid == target.pid }) else {
            errorMessage = tr("请先打开音乐或 Spotify 并选择曲目。")
            return
        }
        let requestGeneration = generation
        let lifetime = actionLifetime
        queue.async { [bridge, weak self] in
            guard lifetime.isActive,
                  let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
                  app.bundleIdentifier == target.bundleID else { return }
            let result = Result { try bridge.control(target, command: command, position: position) }
            Task { @MainActor [weak self] in
                guard let self, started, generation == requestGeneration else { return }
                if case .failure(let error) = result { errorMessage = describe(error, player: target.name) }
                else { poll() }
            }
        }
    }

    private func describe(_ error: Error, player: String) -> String {
        let code = (error as NSError).code
        if code == -1743 {
            return String(format: tr("请在系统设置 → 隐私与安全性 → 自动化中允许 Real 控制 %@，然后点击“允许播放器控制”。"), player)
        }
        if code == -1744 {
            return String(format: tr("尚未获得 %@ 的自动化权限，请点击“允许播放器控制”。"), player)
        }
        if code == -600 { return String(format: tr("%@ 已关闭。"), player) }
        if code == -1712 { return String(format: tr("%@ 未及时响应。"), player) }
        let message = (error as NSError).domain == "real.Media" || error.localizedDescription == "播放器请求失败。"
            ? tr(error.localizedDescription) : error.localizedDescription
        return "\(player): \(message)"
    }
}
