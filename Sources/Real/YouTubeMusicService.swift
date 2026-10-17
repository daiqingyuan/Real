import AppKit
import Combine
import Foundation

/// YTMDesktop v2 Companion Server v1 only. This is not the Google or Pear Desktop API.
/// Protocol reference: https://ytmdesktop.github.io/developer/companion-server/getting-started.html
private final class CompanionSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the user's local companion credential to a redirect destination.
        completionHandler(nil)
    }
}

@MainActor
final class YouTubeMusicService: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceName = "YouTube Music Desktop"
    @Published private(set) var errorMessage: String?
    @Published private(set) var status = tr("未连接")
    @Published private(set) var isEnabled = false
    @Published private(set) var authorizationCode: String?

    private struct State: Decodable {
        struct Player: Decodable { let trackState: Int; let videoProgress: Double }
        struct Video: Decodable {
            struct Thumbnail: Decodable { let url: String; let width: Double; let height: Double }
            let title: String
            let author: String
            let album: String?
            let durationSeconds: Double
            let id: String
            let thumbnails: [Thumbnail]
        }
        let player: Player?
        let video: Video?
    }
    private struct CodeResponse: Decodable { let code: String }
    private struct TokenResponse: Decodable { let token: String }
    private struct CompanionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var baseURL = URL(string: "http://localhost:9863/api/v1")!
    private var token = ""
    private var configurationValid = true
    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var authTask: Task<String?, Never>?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var artworkKey = ""
    private var blockedUntil = Date.distantPast
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 40
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: CompanionSessionDelegate(), delegateQueue: nil)
    }

    /// Stores configuration in memory only. The caller owns any Keychain persistence.
    /// No request occurs here, even when a token has already been supplied.
    func configure(baseURL value: String, token: String) {
        stop()
        blockedUntil = .distantPast // A previous server cannot throttle a new configuration.
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              (components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))),
              let url = components.url else {
            configurationValid = false
            errorMessage = tr("请使用 HTTPS 伴侣服务器地址，或本机 HTTP 地址；不要在地址中包含凭据。")
            status = tr("服务器地址无效")
            return
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "api/v1" else {
            configurationValid = false
            errorMessage = tr("请使用以 /api/v1 结尾的 YTMDesktop 服务器地址。")
            status = tr("接口路径无效")
            return
        }
        baseURL = path.isEmpty ? url.appendingPathComponent("api/v1") : url
        configurationValid = true
        errorMessage = nil
        status = tr("可开始连接")
    }

    /// Call only following the user's explicit Enable action.
    func start() {
        guard configurationValid else { return }
        guard !isEnabled else { return }
        isEnabled = true
        epoch = UUID()
        errorMessage = nil
        if token.isEmpty { status = tr("请授权 YTMDesktop 或输入伴侣令牌") }
        else { beginPolling() }
    }

    func stop() {
        isEnabled = false
        epoch = UUID()
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        authTask?.cancel()
        authTask = nil
        commandTasks.values.forEach { $0.cancel() }
        commandTasks.removeAll()
        authorizationCode = nil
        clearTrack()
        errorMessage = nil
        status = tr("未连接")
    }

    /// Explicit two-step pairing. Show authorizationCode while the user approves in YTMDesktop.
    /// Returns the new token for the caller to save securely; never prints or persists it here.
    func requestAuthorization() async -> String? {
        guard isEnabled, configurationValid, authTask == nil, !Task.isCancelled else { return nil }
        pollTask?.cancel()
        pollTask = nil
        let currentEpoch = epoch
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                status = tr("正在请求伴侣授权…")
                let data = try await request("auth/requestcode", body: ["appId": "real", "appName": "Real", "appVersion": "1.0.0"], authenticated: false)
                let code = try JSONDecoder().decode(CodeResponse.self, from: data).code
                guard isEnabled, epoch == currentEpoch, !Task.isCancelled else { return nil }
                authorizationCode = code
                status = tr("请核对授权码，并在 YTMDesktop 中允许 Real")
                let response = try await request("auth/request", body: ["appId": "real", "code": code], authenticated: false, timeout: 35)
                let result = try JSONDecoder().decode(TokenResponse.self, from: response)
                guard isEnabled, epoch == currentEpoch, !Task.isCancelled, !result.token.isEmpty else { return nil }
                token = result.token
                errorMessage = nil
                status = tr("已授权")
                return result.token
            } catch {
                guard epoch == currentEpoch, !Task.isCancelled else { return nil }
                errorMessage = error.localizedDescription
                status = tr("授权失败")
                return nil
            }
        }
        authTask = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard epoch == currentEpoch else { return nil }
        authTask = nil
        authorizationCode = nil
        if !token.isEmpty { beginPolling() }
        return result
    }

    func playPause() { command("playPause") }
    func next() { command("next") }
    func previous() { command("previous") }
    func seek(to value: Double) {
        guard value.isFinite, duration > 0 else { return }
        command("seekTo", value: min(duration, max(0, value)))
    }

    private func beginPolling() {
        guard isEnabled, !token.isEmpty else { return }
        pollTask?.cancel()
        let currentEpoch = epoch
        pollTask = Task { [weak self] in
            var failureCount = 0
            while !Task.isCancelled {
                guard self?.isEnabled == true, self?.epoch == currentEpoch else { return }
                let wait = self?.blockedUntil.timeIntervalSinceNow ?? 0
                do {
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(min(wait, 86_400) * 1_000_000_000)) }
                    guard let self, isEnabled, epoch == currentEpoch, !Task.isCancelled else { return }
                    let data = try await request("state")
                    let state = try JSONDecoder().decode(State.self, from: data)
                    guard isEnabled, epoch == currentEpoch, !Task.isCancelled else { return }
                    apply(state)
                    status = state.video == nil ? tr("已连接 · 等待播放") : tr("已连接")
                    errorMessage = nil
                    failureCount = 0
                } catch {
                    guard let self, isEnabled, epoch == currentEpoch, !Task.isCancelled else { return }
                    clearTrack()
                    errorMessage = error.localizedDescription
                    status = tr("伴侣服务器不可用")
                    failureCount = min(4, failureCount + 1)
                    if token.isEmpty { return }
                }
                // No strong service reference spans the repeating idle wait.
                do { try await Task.sleep(nanoseconds: UInt64(failureCount == 0 ? 2 : min(30, 2 << failureCount)) * 1_000_000_000) }
                catch { return }
            }
        }
    }

    deinit {
        pollTask?.cancel(); artworkTask?.cancel(); authTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
    }

    private func request(_ path: String, body: [String: Any]? = nil, authenticated: Bool = true, timeout: Double = 5) async throws -> Data {
        try Task.checkCancellation()
        guard isEnabled, configurationValid else { throw CancellationError() }
        guard Date() >= blockedUntil else { throw CompanionError(message: tr("伴侣服务器请求过于频繁，正在等待重试。")) }
        let requestEpoch = epoch
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard !token.isEmpty else { throw CompanionError(message: tr("请先在 YTMDesktop 中授权 Real。")) }
            request.setValue(token, forHTTPHeaderField: "Authorization") // The protocol uses a raw token, not Bearer.
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard isEnabled, epoch == requestEpoch else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401 || response.statusCode == 403 {
            if authenticated { token = "" }
            throw CompanionError(message: tr("伴侣服务器拒绝访问，请在 YTMDesktop 中重新授权 Real。"))
        }
        if response.statusCode == 429 {
            let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
            blockedUntil = Date().addingTimeInterval(max(1, min(seconds, 86_400)))
            throw CompanionError(message: tr("伴侣服务器请求过于频繁，正在等待重试。"))
        }
        guard (200...299).contains(response.statusCode), data.count <= 2_000_000 else {
            throw CompanionError(message: String(format: tr("伴侣请求失败（HTTP %@）。请确认已启用 YTMDesktop v2 伴侣服务器。"), String(response.statusCode)))
        }
        return data
    }

    private func command(_ name: String, value: Double? = nil) {
        guard isEnabled, !token.isEmpty, !title.isEmpty, authTask == nil else { return }
        let currentEpoch = epoch
        let commandID = UUID()
        commandTasks[commandID] = Task { [weak self] in
            guard let self, isEnabled, epoch == currentEpoch, !Task.isCancelled else { return }
            defer { commandTasks.removeValue(forKey: commandID) }
            do {
                var body: [String: Any] = ["command": name]
                if let value { body["data"] = value }
                _ = try await request("command", body: body)
                guard epoch == currentEpoch else { return }
                errorMessage = nil
            } catch {
                guard epoch == currentEpoch, isEnabled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ state: State) {
        guard let video = state.video else { clearTrack(); return }
        title = video.title
        artist = video.author
        album = video.album ?? ""
        duration = video.durationSeconds.isFinite ? max(0, video.durationSeconds) : 0
        let progress = state.player?.videoProgress ?? 0
        position = progress.isFinite ? min(duration > 0 ? duration : .greatestFiniteMagnitude, max(0, progress)) : 0
        isPlaying = state.player?.trackState == 1
        let thumbnail = video.thumbnails.max { $0.width * $0.height < $1.width * $1.height }?.url ?? ""
        let key = "\(video.id)\u{0}\(thumbnail)"
        guard artworkKey != key else { return }
        artworkKey = key
        artworkTask?.cancel()
        artwork = nil
        guard let url = URL(string: thumbnail), url.scheme == "https" else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Intentionally create a separate request without the companion Authorization header.
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await session.data(for: request)
                guard isEnabled, !Task.isCancelled, artworkKey == key, data.count <= 8_000_000,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                artwork = NSImage(data: data)
            } catch { /* Album art is optional. */ }
        }
    }

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        duration = 0
        position = 0
        isPlaying = false
        artworkTask?.cancel()
        artworkKey = ""
        artwork = nil
    }
}
