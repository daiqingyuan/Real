import Foundation
import SwiftUI

/// Search results contain destinations only. Selecting a result cannot grant
/// access, reset settings, quit, remove files, or run a repair by itself.
struct SettingsSearchEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let page: String
    let module: String?
    let anchor: String
    let expand: String?
    let keywords: String
    let localizedTitles: [String: String]

    init(id: String, title: String, page: String, module: String? = nil,
         anchor: String, expand: String? = nil, keywords: String = "",
         localizedTitles: [String: String] = [:]) {
        self.id = id; self.title = title; self.page = page; self.module = module
        self.anchor = anchor; self.expand = expand; self.keywords = keywords
        self.localizedTitles = localizedTitles
    }

    func localizedTitle(language: String) -> String {
        let language = SettingsSearchIndex.languageKey(language)
        return language == "zh-Hans" ? title : localizedTitles[language] ?? localizedTitles["en"] ?? title
    }
}

enum SettingsSearchIndex {
    static func languageKey(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("zh") { return "zh-Hans" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ru") { return "ru" }
        return "en"
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    static func tokens(in value: String) -> [String] {
        var seen = Set<String>()
        return normalized(String(value.prefix(512)))
            .split(whereSeparator: { $0.isWhitespace || [",", "，", ";", "；", "、", "|", "/"].contains(String($0)) })
            .prefix(32).map(String.init).filter { seen.insert($0).inserted }
    }

    static func search(_ query: String, language: String,
                       entries: [SettingsSearchEntry] = SettingsSearchIndex.entries, limit: Int = 12) -> [SettingsSearchEntry] {
        let terms = tokens(in: query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let phrase = terms.joined(separator: " ")
        return entries.enumerated().compactMap { index, entry -> (SettingsSearchEntry, Int, Int)? in
            let currentTitle = normalized(entry.localizedTitle(language: language))
            let allTitles = [entry.title] + Array(entry.localizedTitles.values)
            let haystack = normalized(([entry.keywords] + allTitles).joined(separator: " "))
            guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            let score = (currentTitle == phrase ? 100 : currentTitle.hasPrefix(phrase) ? 60 : 0)
                + terms.filter { currentTitle.contains($0) }.count * 10
            return (entry, score, index)
        }.sorted {
            $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1
        }.prefix(min(limit, 50)).map(\.0)
    }

    private static func entry(_ id: String, _ title: String, _ page: String,
                              module: String? = nil, anchor: String, expand: String? = nil,
                              en: String, ja: String, ru: String, aliases: String) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, title: title, page: page, module: module, anchor: anchor,
            expand: expand, keywords: aliases, localizedTitles: ["en": en, "ja": ja, "ru": ru])
    }

    static let entries: [SettingsSearchEntry] = [
        entry("dock.behavior", "启用点击收起", "dock", anchor: "dock.behavior",
              en: "Click to hide and restore", ja: "クリックで収納と復元", ru: "Сворачивать и восстанавливать по щелчку",
              aliases: "程序坞 任务栏 点击 缩小 最小化 恢复 多窗口 当前桌面 Dock minimize restore windows current desktop クリック 最小化 復元 ウインドウ окно свернуть восстановить"),
        entry("dock.exclusions", "排除应用", "dock", anchor: "dock.behavior",
              en: "Excluded apps", ja: "除外するアプリ", ru: "Исключённые приложения",
              aliases: "程序坞 不收起 忽略 例外 白名单 黑名单 选择 软件 名称 图标 标识 bundle ID Dock exclusions exclude exception ignore applications 除外 アプリ 検索 исключения приложения поиск"),
        entry("dock.presence", "Real 的图标", "dock", anchor: "dock.presence",
              en: "Real icons", ja: "Real のアイコン", ru: "Значки Real",
              aliases: "程序坞 图标 菜单栏 隐藏 显示 后台 dock icon menu bar hide show background アイコン メニューバー 非表示 バックグラウンド значок меню скрыть фон"),
        entry("permissions", "权限", "preferences", anchor: "permissions",
              en: "Permissions", ja: "アクセス権", ru: "Разрешения",
              aliases: "授权 辅助功能 输入监控 屏幕录制 隐私 安全 accessibility input monitoring screen recording privacy permission アクセシビリティ 入力監視 画面収録 許可 специальные возможности мониторинг ввода запись экрана доступ"),
        entry("music.module", "音乐与歌词", "island", module: "music", anchor: "music.playback",
              en: "Music and lyrics", ja: "音楽と歌詞", ru: "Музыка и текст песен",
              aliases: "灵动岛 开关 音乐 模块 播放器 启用 music player module enable 音楽 プレーヤー 有効 музыка проигрыватель модуль включить"),
        entry("music.lyrics", "歌词", "island", module: "music", anchor: "music.lyrics",
              en: "Lyrics", ja: "歌詞", ru: "Текст песни",
              aliases: "悬浮 歌词 桌面 粉色 文字 滚动 悬停 收起 英文 翻译 lyrics text floating pink scroll marquee hover translation 歌詞 文字 スクロール 翻訳 текст песен строки прокрутка перевод"),
        entry("music.lyrics.font", "歌词字号", "island", module: "music", anchor: "music.lyrics",
              en: "Lyric text size", ja: "歌詞の文字サイズ", ru: "Размер текста песни",
              aliases: "歌词 字体 字号 大小 小 标准 大 font size lyrics text small standard large 歌詞 フォント サイズ 文字 шрифт размер текст песни"),
        entry("music.lyrics.color", "悬浮歌词颜色", "island", module: "music", anchor: "music.lyrics",
              en: "Floating lyric color", ja: "フローティング歌詞の色", ru: "Цвет плавающего текста песни",
              aliases: "歌词 颜色 色盘 粉色 背景 深浅 透明度 color colour palette pink background opacity lyrics 歌詞 色 背景 透明度 цвет палитра фон прозрачность"),
        entry("music.lyrics.sync", "歌词同步微调", "island", module: "music", anchor: "music.lyrics",
              en: "Lyric timing adjustment", ja: "歌詞のタイミング調整", ru: "Настройка синхронизации текста",
              aliases: "歌词 同步 提前 延后 延迟 早 晚 进度 错位 单曲 timing sync offset early late delay track lyrics 歌詞 同期 遅延 調整 синхронизация задержка раньше позже текст"),
        entry("music.source", "播放来源", "island", module: "music", anchor: "music.playback", expand: "music",
              en: "Playback source", ja: "再生元", ru: "Источник воспроизведения",
              aliases: "音乐 歌曲 自动 切换 最近 QQ 音乐 QQMusic 网易云 NetEase Cloud Music Apple Music Spotify YTM YouTube Companion 伴侣服务器 令牌 token source player auto switch 再生 自動 切替 音楽 источник автоматически переключать музыка"),
        entry("music.controls", "五个控制位置", "island", module: "music", anchor: "music.playback", expand: "music",
              en: "Five control positions", ja: "5 つの操作位置", ru: "Пять позиций управления",
              aliases: "播放器 上一首 下一首 播放 暂停 静音 音量 排列 按钮 进度 拖动 controls previous next play pause mute volume seek slots プレーヤー 前 次 再生 一時停止 音量 操作 управление предыдущая следующая пауза громкость перемотка"),
        entry("music.appearance", "更多音乐设置", "island", module: "music", anchor: "music.playback", expand: "music",
              en: "More music settings", ja: "その他の音楽設定", ru: "Дополнительные настройки музыки",
              aliases: "彩色 频谱 音频 声音 封面 配色 模糊 全屏 隐藏 暂停 保留 超时 spectrum audio sound cover tint blur fullscreen idle timeout 音楽 スペクトラム 音声 ジャケット ぼかし 全画面 спектр звук обложка размытие полноэкранный ожидание"),
        entry("island.appearance", "外观与展开方式", "island", anchor: "island.appearance",
              en: "Appearance and expansion", ja: "外観と展開方法", ru: "Внешний вид и раскрытие",
              aliases: "灵动岛 刘海 悬停 展开 收起 等待 延迟 动画 notch island hover expand collapse delay animation 外観 ノッチ ホバー 展開 待機 островок вырез наведение раскрытие задержка"),
        entry("island.displays", "首选显示器", "island", anchor: "island.appearance",
              en: "Preferred display", ja: "優先ディスプレイ", ru: "Предпочитаемый дисплей",
              aliases: "灵动岛 屏幕 显示器 所有 主 外接 自动 切换 多屏 display monitor screen all main external automatic ディスプレイ 画面 外部 自動 дисплей экран монитор внешний автоматически"),
        entry("island.more", "更多外观设置", "island", anchor: "island.appearance", expand: "appearance",
              en: "More appearance settings", ja: "その他の外観設定", ru: "Дополнительные настройки внешнего вида",
              aliases: "灵动岛 高度 触觉 反馈 上次 标签页 始终 设置 入口 阴影 锁屏 隐藏 height haptics feedback remember tab tabs settings shadow lock screen 高さ 触覚 タブ 影 ロック высота тактильный вкладки тень блокировка"),
        entry("calendar", "日历与提醒", "island", module: "calendar", anchor: "module.calendar",
              en: "Calendar and reminders", ja: "カレンダーとリマインダー", ru: "Календарь и напоминания",
              aliases: "日历 提醒 事项 日程 全天 完成 标题 滚动 列表 授权 来源 calendar reminder event all day completed titles scroll access sources カレンダー リマインダー 予定 終日 完了 календарь напоминания события весь день завершённые"),
        entry("shelf", "文件暂存", "island", module: "shelf", anchor: "module.shelf",
              en: "File shelf", ja: "ファイルの一時保管", ru: "Полка файлов",
              aliases: "暂存架 文件 拖入 拖出 复制 移除 优先 扩大 区域 添加 shelf files drag drop copy remove priority target add ファイル シェルフ ドラッグ コピー 追加 полка файлы перетаскивание копировать добавить"),
        entry("hud", "系统提示", "island", module: "hud", anchor: "module.hud",
              en: "System indicators", ja: "システム表示", ru: "Системные индикаторы",
              aliases: "HUD 系统 音量 亮度 百分比 提示 预览 volume brightness percent indicator preview システム 音量 明るさ パーセント громкость яркость проценты индикатор"),
        entry("mirror", "镜子与趣味", "island", module: "mirror", anchor: "module.mirror",
              en: "Mirror and extras", ja: "ミラーと遊び", ru: "Зеркало и дополнения",
              aliases: "镜子 镜像 摄像头 相机 圆形 闲置 表情 camera mirror round face idle カメラ ミラー 鏡 丸 表情 камера зеркало круглый лицо"),
        entry("preferences.language", "界面语言", "preferences", anchor: "preferences.general",
              en: "Interface language", ja: "表示言語", ru: "Язык интерфейса",
              aliases: "语言 中文 英语 英文 日语 俄语 跟随 系统 language Chinese English Japanese Russian system 日本語 英語 中国語 ロシア語 システム 言語 язык русский английский японский китайский системный"),
        entry("preferences.login", "登录时启动", "preferences", anchor: "preferences.general",
              en: "Launch at login", ja: "ログイン時に起動", ru: "Запуск при входе",
              aliases: "开机 登录 自启 启动 后台 自动 安静 login launch startup boot autostart background ログイン 起動 自動 バックグラウンド автозапуск вход запуск фон"),
        entry("preferences.intro", "首次打开时显示品牌动画", "preferences", anchor: "preferences.general",
              en: "Show branding on first open", ja: "初回起動時にブランドアニメーションを表示", ru: "Анимация бренда при первом открытии",
              aliases: "品牌 动画 首次 打开 R real 预加载 启动 intro branding animation first launch splash アニメーション 初回 起動 анимация заставка первый запуск"),
        entry("runtime.health", "检查与修复", "preferences", anchor: "runtime.health",
              en: "Check and repair", ja: "確認と修復", ru: "Проверка и восстановление",
              aliases: "自检 运行 状态 健康 故障 没反应 后台 重新 连接 检查 修复 诊断 health check repair reconnect status background troubleshooting self test 接続 状態 確認 修復 診断 проверка восстановление состояние подключение диагностика"),
        entry("preferences.support", "关于 Real", "preferences", anchor: "preferences.support",
              en: "About Real", ja: "Real について", ru: "О Real",
              aliases: "关于 版本 作者 dan 支持 退出 about version author support quit 終了 バージョン версия автор выход"),
        entry("runtime.diagnostics", "导出诊断", "preferences", anchor: "runtime.diagnostics",
              en: "Export diagnostics", ja: "診断を書き出す", ru: "Экспорт диагностики",
              aliases: "导出 诊断 日志 export diagnostic log 診断 書き出す диагностика экспорт журнал"),
        entry("preferences.uninstall", "卸载 Real", "preferences", anchor: "preferences.uninstall",
              en: "Uninstall Real", ja: "Real をアンインストール", ru: "Удалить Real",
              aliases: "卸载 删除 移除 清理 保留 设置 数据 uninstall remove delete cleanup keep settings data アンインストール 削除 設定 データ удаление удалить очистка настройки данные")
    ]
}

@MainActor
struct SettingsSearchResults: View {
    let query: String
    let language: String
    let onSelect: (SettingsSearchEntry) -> Void
    private var results: [SettingsSearchEntry] { SettingsSearchIndex.search(query, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(tr("没有找到相关设置。"))
                    .foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(results) { entry in
                    Button { onSelect(entry) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.localizedTitle(language: language)).font(.body)
                                Text(tr(entry.page == "dock" ? "程序坞" : entry.page == "island" ? "灵动岛" : "偏好设置"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if entry.id != results.last?.id { Divider().padding(.horizontal, 14) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }
}
