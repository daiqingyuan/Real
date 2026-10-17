import AppKit
import SwiftUI

enum CompactStyle {
    static let contentSize = NSSize(width: 960, height: 658)
    static let sidebarWidth: CGFloat = 168
    static let surface = Color(nsColor: .textBackgroundColor)
    static let rail = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.118, green: 0.125, blue: 0.141, alpha: 1)
            : NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)
    })
    static let selected = Color.primary.opacity(0.07)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.847, green: 0.667, blue: 0.569, alpha: 1)
            : NSColor(srgbRed: 0.588, green: 0.416, blue: 0.337, alpha: 1)
    })
}

struct CompactSection<Content: View>: View {
    @ObservedObject private var preferences = Preferences.shared
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty { Text(tr(title)).font(.system(size: 13, weight: .medium)).padding(.bottom, 5) }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct CompactToggle: View {
    @ObservedObject var p: Preferences
    let key: String
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(tr(title))
                Spacer(minLength: 12)
                Toggle(tr(title), isOn: p.binding(key)).labelsHidden().toggleStyle(.switch)
                    .controlSize(.small).accessibilityIdentifier("real.setting." + key)
            }.padding(.vertical, 9)
            Divider().opacity(0.55)
        }
    }
}
struct CompactNote: View {
    @ObservedObject private var preferences = Preferences.shared
    let text: String
    var body: some View {
        Text(tr(text)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
    }
}
struct CompactRow<Content: View>: View {
    @ObservedObject private var preferences = Preferences.shared
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) { Text(tr(title)); Spacer(minLength: 16); content() }.padding(.vertical, 9)
            Divider().opacity(0.55)
        }
    }
}
