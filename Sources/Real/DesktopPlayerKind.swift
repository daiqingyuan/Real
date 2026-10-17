import Foundation

enum DesktopPlayerKind: String, Sendable {
    case qq, netease

    var bundleID: String {
        switch self {
        case .qq: return "com.tencent.QQMusicMac"
        case .netease: return "com.netease.163music"
        }
    }
    var sourceName: String { self == .qq ? "QQ Music" : "网易云音乐" }
    var menuTitles: Set<String> {
        self == .qq ? ["播放控制", "Playback", "Controls"] : ["控制", "Controls", "Control"]
    }
}
