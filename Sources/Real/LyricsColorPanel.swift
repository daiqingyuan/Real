import AppKit
import SwiftUI

/// A standard macOS palette with an explicitly owned target. Keeping the action
/// receiver alive also makes selection reliable when the settings view redraws.
@MainActor final class LyricsColorPanel: NSObject {
    static let shared = LyricsColorPanel()
    private weak var preferences: Preferences?

    func show(for preferences: Preferences) {
        self.preferences = preferences
        let panel = NSColorPanel.shared
        panel.title = tr("歌词高亮颜色")
        panel.identifier = NSUserInterfaceItemIdentifier("real.lyrics-color")
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(preferences.lyricsColor)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        preferences?.setLyricsColor(Color(nsColor: sender.color))
    }
}
