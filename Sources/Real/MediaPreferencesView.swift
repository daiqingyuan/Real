import SwiftUI

struct MediaPreferencesView: View {
    @ObservedObject var media: MediaService
    @ObservedObject var youtube: YouTubeMusicService
    @ObservedObject var preferences: Preferences
    var preview = false
    @State private var token = ""
    @State private var storageMessage = ""
    @State private var authorizing = false
    @State private var loadedURL = ""

    private let slotNames = ["previous", "play", "next", "mute", "volume"]
    private let slotLabels = ["上一首", "播放与暂停", "下一首", "静音", "音量"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(tr("播放来源"), selection: $preferences.mediaSource) {
                Text(tr("自动跟随正在播放的应用")).tag("auto")
                Text(tr("QQ 音乐")).tag("qq")
                Text(tr("网易云音乐")).tag("netease")
                Text("YTMDesktop").tag("ytm")
            }
            if preferences.mediaSource == "auto" {
                Text(tr("自动跟随最近开始播放的应用；全部暂停时，保留最后显示的歌曲。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if ["qq", "netease"].contains(preferences.mediaSource) {
                Text(tr("请在音乐应用中开始播放。Real 使用已有的辅助功能权限读取播放状态并控制播放。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if preferences.mediaSource == "ytm" {
                Text(tr("仅支持 YTMDesktop v2 的 Companion Server。请先在该应用中启用伴侣服务器。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(tr("伴侣服务器地址"), text: $preferences.youtubeURL)
                    .textFieldStyle(.roundedBorder).disabled(authorizing)
                SecureField(tr("伴侣令牌（可通过授权获取）"), text: $token)
                    .textFieldStyle(.roundedBorder).disabled(authorizing)
                HStack {
                    Button(tr("保存并连接"), action: connect).disabled(authorizing || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(tr("授权 YTMDesktop"), action: authorize).disabled(authorizing)
                    if youtube.isEnabled { Button(tr("断开连接")) { youtube.stop(); authorizing = false } }
                }
                HStack {
                    Button(tr("读取已存令牌"), action: loadToken).disabled(authorizing)
                    Button(tr("删除已存令牌"), action: removeToken).disabled(authorizing)
                }.font(.caption)
                if let code = youtube.authorizationCode {
                    Text(tr("请核对授权码：") + " " + code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if authorizing { ProgressView().controlSize(.small) }
                Text(youtube.status).font(.caption).foregroundStyle(.secondary)
                if let error = youtube.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if !storageMessage.isEmpty { Text(storageMessage).font(.caption).foregroundStyle(.secondary) }
                Text(tr("令牌仅保存到此 Mac 的钥匙串。连接和授权均需点击按钮；不会自动启动播放器。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Button(tr("允许播放器控制")) {
                        guard !preview else { return }
                        media.requestAuthorization()
                    }.disabled(preview || media.isRequestingAuthorization)
                    if media.isRequestingAuthorization { ProgressView().controlSize(.small) }
                }
                Text(tr("只会请求控制已经运行的音乐或 Spotify，不会打开播放器。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status = media.authorizationStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text(media.sourceName.isEmpty ? tr("打开音乐或 Spotify 开始播放") : media.sourceName)
                    .font(.caption).foregroundStyle(.secondary)
                if let error = media.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            Text(tr("五个控制位置")).font(.subheadline.weight(.medium))
            ForEach(0..<5, id: \.self) { index in
                Picker(tr("位置") + " \(index + 1)", selection: slotBinding(index)) {
                    ForEach(Array(slotNames.enumerated()), id: \.offset) { item in
                        Text(tr(slotLabels[item.offset])).tag(item.element)
                    }
                }
            }
            Text(tr("系统音量与静音取决于当前音频输出设备是否支持软件控制。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(preview)
        .onAppear { if !preview, preferences.mediaSource == "ytm", loadedURL != preferences.youtubeURL { loadToken() } }
        .onChange(of: preferences.youtubeURL) { _, _ in guard !preview else { return }; youtube.stop(); token = ""; storageMessage = "" }
        .onChange(of: preferences.mediaSource) { _, source in
            guard !preview else { return }
            if source != "ytm" { youtube.stop(); authorizing = false }
            else if loadedURL != preferences.youtubeURL { loadToken() }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<String> {
        Binding(get: {
            let value = preferences.controllerSlots.indices.contains(index) ? preferences.controllerSlots[index] : slotNames[index]
            return slotNames.contains(value) ? value : slotNames[index]
        }, set: { value in
            guard !preview else { return }
            var values = (0..<5).map { preferences.controllerSlots.indices.contains($0) ? preferences.controllerSlots[$0] : slotNames[$0] }
            values[index] = value
            preferences.controllerSlots = values
        })
    }

    private func loadToken() {
        guard !preview else { return }
        loadedURL = preferences.youtubeURL
        do {
            token = try MediaTokenStore.read(for: preferences.youtubeURL) ?? ""
            storageMessage = token.isEmpty ? tr("此服务器没有已保存的令牌。") : tr("已从钥匙串读取令牌。")
        } catch { storageMessage = error.localizedDescription }
    }

    private func removeToken() {
        guard !preview else { return }
        youtube.stop()
        do {
            try MediaTokenStore.remove(for: preferences.youtubeURL)
            token = ""
            storageMessage = tr("已删除此服务器的令牌。")
        } catch { storageMessage = error.localizedDescription }
    }

    private func connect() {
        guard !preview else { return }
        youtube.configure(baseURL: preferences.youtubeURL, token: token)
        guard youtube.errorMessage == nil else { return }
        do {
            try MediaTokenStore.save(token, for: preferences.youtubeURL)
            storageMessage = tr("令牌已保存到钥匙串。")
        } catch { storageMessage = error.localizedDescription }
        youtube.start()
    }

    private func authorize() {
        guard !preview else { return }
        youtube.configure(baseURL: preferences.youtubeURL, token: "")
        guard youtube.errorMessage == nil else { return }
        youtube.start()
        authorizing = true
        let serverURL = preferences.youtubeURL
        Task { @MainActor in
            let result = await youtube.requestAuthorization()
            authorizing = false
            guard let result, youtube.isEnabled, preferences.mediaSource == "ytm", preferences.youtubeURL == serverURL else { return }
            token = result
            do {
                try MediaTokenStore.save(result, for: serverURL)
                storageMessage = tr("授权成功，令牌已保存到钥匙串。")
            } catch { storageMessage = error.localizedDescription }
        }
    }
}
