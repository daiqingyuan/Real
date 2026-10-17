import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Shared by the host and its regression tests; contains no AppKit state.
enum IslandInteractionPolicy {
    static func expandedTab(current: String, preferShelf: Bool, shelfEnabled: Bool,
                            shelfPriority: Bool, hasShelfItems: Bool) -> String {
        preferShelf && shelfEnabled && shelfPriority && hasShelfItems ? "shelf" : current
    }

    static func shouldCollapse(expanded: Bool, pointerInside: Bool,
                               popoverOpen: Bool, shelfDragActive: Bool) -> Bool {
        expanded && !pointerInside && !popoverOpen && !shelfDragActive
    }
}

/// The hover target survives removal of the lyric view and shrinkage of its
/// window. Using the view's exit event would immediately show/hide it in a loop.
struct FloatingLyricsHoverState {
    private(set) var hidden = false
    private var restoreAfter: TimeInterval?

    mutating func update(pointer: CGPoint, lyricRegion: CGRect?, mousePressed: Bool,
                         now: TimeInterval) -> Bool {
        guard let region = lyricRegion, !region.isEmpty, !region.isInfinite, !region.isNull else {
            hidden = false; restoreAfter = nil; return hidden
        }
        let target = hidden ? region.insetBy(dx: -4, dy: -3) : region
        if target.contains(pointer) {
            hidden = true; restoreAfter = nil
        } else if hidden {
            // Finish underlying clicks/drags before bringing the overlay back.
            if mousePressed { restoreAfter = nil }
            else if let deadline = restoreAfter {
                if now >= deadline { hidden = false; restoreAfter = nil }
            } else { restoreAfter = now + 0.12 }
        }
        return hidden
    }
}

@MainActor final class IslandHost {
    private var panels: [String: IslandPanel] = [:]
    private var screenObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var locked = false
    private var dragMonitor: Any?
    private var policyTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    let model: AppModel
    init(model: AppModel) {
        self.model = model
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        policyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.previewOnly else { return }
                let p = self.model.preferences
                if p.enabled("hideFullscreen") || (!p.enabled("allDisplays") && p.enabled("automaticDisplay")) { self.refresh() }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.locked = true; self?.refresh() } }
        unlockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.locked = false; self?.refresh() } }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.previewOnly, self.model.preferences.enabled("shelf"), self.model.preferences.enabled("shelfOnDrag"), NSPasteboard(name: .drag).types?.contains(.fileURL) == true else { return }
                let point = NSEvent.mouseLocation
                for panel in self.panels.values {
                    let extra: CGFloat = self.model.preferences.enabled("shelfLargeTarget") ? 70 : 0
                    if panel.frame.insetBy(dx: -extra, dy: -20).contains(point) { self.model.islandTab = "shelf"; panel.setExpanded(true) }
                }
            }
        }
    }
    func refresh() {
        guard !model.previewOnly, !model.isUninstalling else { stop(); return }
        let p = model.preferences
        if locked && p.enabled("hideLocked") { panels.values.forEach { $0.orderOut(nil) }; model.mirror.stop(); return }
        let screens = DisplayPolicy.selectedScreens(allDisplays: p.enabled("allDisplays"), selectedID: p.selectedDisplay, automatic: p.enabled("automaticDisplay"))
        let names = Set(screens.map(screenKey))
        for key in Array(panels.keys) where !names.contains(key) { panels.removeValue(forKey: key)?.close() }
        for screen in screens {
            let key = screenKey(screen)
            let panel = panels[key] ?? IslandPanel(model: model, screen: screen)
            panels[key] = panel; panel.hostScreen = screen
            if p.enabled("hideFullscreen") && DisplayPolicy.shouldHideForFullscreen(on: screen) { panel.setExpanded(false); panel.orderOut(nil) }
            else { panel.refreshFrame(); if !panel.isVisible { panel.orderFrontRegardless() } }
        }
    }
    func stop() { panels.values.forEach { $0.close() }; panels.removeAll(); model.mirror.stop() }
    private func screenKey(_ screen: NSScreen) -> String { DisplayPolicy.identifier(for: screen) }
    deinit {
        policyTimer?.invalidate()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
    }
}

@MainActor final class IslandPanel: NSPanel {
    var hostScreen: NSScreen
    private let model: AppModel
    private var expanded = false
    private var pointerInside = false
    private var volumePopoverOpen = false
    private var measuredHeight: CGFloat = 200
    private var measuredLyricHeight: CGFloat = 33
    private var work: DispatchWorkItem?
    private var settleFrame: DispatchWorkItem?
    private var targetFrame: NSRect?
    private var lyricRegion: NSRect?
    private var lyricHover = FloatingLyricsHoverState()
    private var lyricPointerTimer: Timer?
    private let presentation = IslandPresentation()
    init(model: AppModel, screen: NSScreen) {
        self.model = model; hostScreen = screen
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; level = .statusBar
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false; isMovable = false
        identifier = NSUserInterfaceItemIdentifier("real.island")
        contentView = NSHostingView(rootView: HostedIsland(model: model, p: model.preferences, presentation: presentation,
            measured: { [weak self] value in
                guard let self, value.isFinite, value > 20, abs(value - self.measuredHeight) > 1 else { return }
                self.measuredHeight = value; if self.expanded { self.refreshFrame() }
            },
            lyricMeasured: { [weak self] height in
                guard let self, height.isFinite, height > 0, abs(height - self.measuredLyricHeight) > 0.5 else { return }
                self.measuredLyricHeight = height
                if !self.expanded { self.refreshFrame() }
            },
            hover: { [weak self] value in self?.hover(value) },
            lyricEntered: { [weak self] in self?.sampleLyricPointer() },
            popoverChanged: { [weak self] value in self?.popoverChanged(value) },
            expand: { [weak self] in self?.setExpanded(true) },
            drop: { [weak self] providers in
                guard let self, self.model.preferences.enabled("shelf") else { return false }
                self.model.islandTab = "shelf"; self.setExpanded(true, preferShelf: false)
                return acceptFiles(providers, service: self.model.shelf)
            }))
        refreshFrame()
        // Read pointer position only. No global input hook or new permission is
        // needed, and the vanished strip does not leave an invisible hit target.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLyricPointer() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        lyricPointerTimer = timer
    }
    override func close() {
        lyricPointerTimer?.invalidate(); lyricPointerTimer = nil
        work?.cancel(); settleFrame?.cancel()
        super.close()
    }
    private func sampleLyricPointer() {
        guard isVisible else { return }
        let previous = lyricHover.hidden
        updateLyricHover()
        if lyricHover.hidden != previous { refreshFrame() }
    }
    private func updateLyricHover() {
        let point = NSEvent.mouseLocation
        let hidden = lyricHover.update(pointer: point, lyricRegion: lyricRegion,
            mousePressed: NSEvent.pressedMouseButtons != 0, now: ProcessInfo.processInfo.systemUptime)
        if presentation.lyricsOccluded != hidden {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) {
                presentation.lyricsOccluded = hidden
            }
        }
        // During the upward animation the reserved panel still covers the old
        // strip. Let clicks reach the app below immediately; the island itself
        // stays interactive when the pointer moves into its black surface.
        let islandBottom = hostScreen.frame.maxY - presentation.closedHeight
        ignoresMouseEvents = hidden && !expanded && point.y < islandBottom
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func setExpanded(_ value: Bool, preferShelf: Bool = true) {
        work?.cancel(); guard value != expanded else { return }
        expanded = value
        if value {
            model.islandTab = IslandInteractionPolicy.expandedTab(current: model.islandTab,
                preferShelf: preferShelf, shelfEnabled: model.preferences.enabled("shelf"),
                shelfPriority: model.preferences.enabled("shelfPriority"), hasShelfItems: !model.shelf.items.isEmpty)
        } else { volumePopoverOpen = false }
        if value && model.preferences.enabled("haptics") { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        refreshFrame()
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
            presentation.expanded = value
        }
    }
    private func hover(_ inside: Bool) {
        pointerInside = inside
        work?.cancel()
        if !inside { scheduleCollapse(); return }
        guard model.preferences.enabled("hover") else { return }
        let action = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside else { return }
            self.setExpanded(true)
        }
        work = action
        DispatchQueue.main.asyncAfter(deadline: .now() + model.preferences.hoverDelay, execute: action)
    }
    private func popoverChanged(_ open: Bool) {
        volumePopoverOpen = open
        work?.cancel()
        if !open {
            // A separate popover window may consume the last hover event. Check
            // the pointer on dismissal so the island cannot remain stuck open.
            pointerInside = (targetFrame ?? frame).contains(NSEvent.mouseLocation)
            scheduleCollapse()
        }
    }
    private func scheduleCollapse() {
        work?.cancel()
        guard expanded, !pointerInside, !volumePopoverOpen else { return }
        let action = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let dragging = ShelfDragPolicy.isDraggingFromShelf
            if IslandInteractionPolicy.shouldCollapse(expanded: self.expanded,
                pointerInside: self.pointerInside, popoverOpen: self.volumePopoverOpen,
                shelfDragActive: dragging) {
                self.setExpanded(false)
            } else if dragging {
                // Native drag sessions have their own event tracking loop. Recheck
                // at a bounded rate until completion instead of tearing down its source.
                self.scheduleCollapse()
            }
        }
        work = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }
    func refreshFrame() {
        let p = model.preferences
        let inset = hostScreen.safeAreaInsets.top
        let physicalWidth = hostScreen.auxiliaryTopRightArea.flatMap { right in hostScreen.auxiliaryTopLeftArea.map { right.minX - $0.maxX } } ?? 0
        let baseWidth: CGFloat = physicalWidth > 0 ? physicalWidth + 64 : 188
        let lyricWidth: CGFloat = physicalWidth > 0 ? physicalWidth + 44 : 225
        // Reserve the chosen font's first line before the hosting view reports
        // its complete intrinsic height (including an optional translation).
        let lyricHeight = max(measuredLyricHeight, ceil(LyricDisplayPolicy.fontSize(for: p.lyricsTextSize) * 1.4) + 16)
        let expandedWidth = min(hostScreen.frame.width - 40, p.enabled("calendar") && model.islandTab == "music" ? 640.0 : 480.0)
        let closedHeight: CGFloat = max(inset, p.islandHeight > 0 ? max(24, p.islandHeight) : 30)
        presentation.closedHeight = closedHeight
        lyricRegion = !expanded && model.showFloatingLyrics
            ? NSRect(x: hostScreen.frame.midX - lyricWidth / 2 - 4,
                     y: hostScreen.frame.maxY - closedHeight - 6 - lyricHeight,
                     width: lyricWidth + 8, height: lyricHeight)
            : nil
        updateLyricHover()
        let lyricSlot = lyricRegion != nil && !lyricHover.hidden
        let width: CGFloat = expanded ? expandedWidth : model.hud != nil ? 360 : lyricSlot ? max(lyricWidth, baseWidth) : baseWidth
        let height: CGFloat = expanded ? min(hostScreen.frame.height - 80, measuredHeight) : closedHeight + (lyricSlot ? lyricHeight + 6 : 0) + (model.hud != nil ? inset : 0)
        let rect = NSRect(x: hostScreen.frame.midX - width / 2, y: hostScreen.frame.maxY - height, width: width, height: height)
        hasShadow = expanded && p.enabled("shadow")
        if targetFrame != rect {
            targetFrame = rect
            settleFrame?.cancel()
            if frame == .zero || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                setFrame(rect, display: true)
            } else {
                // Keep the screen-top center fixed. SwiftUI animates the visible
                // surface; the transparent host only reserves enough drawing room.
                let reserveWidth = max(frame.width, rect.width)
                let reserveHeight = max(frame.height, rect.height)
                setFrame(NSRect(x: hostScreen.frame.midX - reserveWidth / 2,
                                y: hostScreen.frame.maxY - reserveHeight,
                                width: reserveWidth, height: reserveHeight), display: false)
                let settle = DispatchWorkItem { [weak self] in
                    guard let self, self.targetFrame == rect else { return }
                    self.setFrame(rect, display: true)
                }
                settleFrame = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + (lyricHover.hidden && !expanded ? 0.22 : 0.4), execute: settle)
            }
        }
        presentation.inset = inset
        presentation.closedWidth = model.hud != nil ? 360 : baseWidth
        presentation.lyricWidth = lyricWidth
        presentation.notchWidth = physicalWidth > 0 ? physicalWidth + 4 : 185
        presentation.closedHeight = closedHeight
        presentation.expandedWidth = expandedWidth
        presentation.expandedHeight = min(hostScreen.frame.height - 80, measuredHeight)
    }
}

@MainActor final class IslandPresentation: ObservableObject {
    @Published var expanded = false
    @Published var lyricsOccluded = false
    @Published var expandedWidth: CGFloat = 640
    @Published var expandedHeight: CGFloat = 200
    @Published var inset: CGFloat = 0
    @Published var closedWidth: CGFloat = 220
    @Published var closedHeight: CGFloat = 32
    @Published var lyricWidth: CGFloat = 225
    @Published var notchWidth: CGFloat = 185
}
private struct HostedIsland: View {
    @ObservedObject var model: AppModel
    @ObservedObject var p: Preferences
    @ObservedObject var presentation: IslandPresentation
    let measured: (CGFloat) -> Void
    let lyricMeasured: (CGFloat) -> Void
    let hover: (Bool) -> Void
    let lyricEntered: () -> Void
    let popoverChanged: (Bool) -> Void
    let expand: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        VStack(spacing: 0) {
            if !presentation.expanded && model.hud != nil && presentation.inset > 0 { Color.black.frame(height: presentation.inset) }
            ZStack(alignment: .top) {
                if presentation.expanded {
                    IslandContent(model: model, p: p, expanded: true, topInset: presentation.inset, notchWidth: presentation.notchWidth, popoverChanged: popoverChanged)
                        .frame(width: presentation.expandedWidth).fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.onAppear { measured(geometry.size.height) }
                                .onChange(of: geometry.size.height) { _, height in measured(height) }
                        })
                        .transition(.opacity)
                } else {
                    IslandContent(model: model, p: p, expanded: false)
                        .frame(width: presentation.closedWidth, height: presentation.closedHeight)
                        .transition(.opacity)
                }
            }
            .frame(width: presentation.expanded ? presentation.expandedWidth : presentation.closedWidth,
                   height: presentation.expanded ? presentation.expandedHeight : presentation.closedHeight, alignment: .top)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: presentation.expanded ? 26 : 14, bottomTrailingRadius: presentation.expanded ? 26 : 14))
            .contentShape(Rectangle())
            .onHover(perform: hover)
            .onTapGesture { if !presentation.expanded { expand() } }
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: drop)
            .zIndex(1)
            if !presentation.expanded && model.showFloatingLyrics && !presentation.lyricsOccluded {
                QQLyricsStrip(player: model.desktopPlayer, lyrics: model.lyrics, preferences: p)
                    .frame(width: presentation.lyricWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { lyricEntered() } }
                    .help(tr("鼠标移入时自动收起，移开后显示"))
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { lyricMeasured(geometry.size.height) }
                            .onChange(of: geometry.size.height) { _, height in lyricMeasured(height) }
                    })
                    .padding(.top, 6).padding(.horizontal, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reducedMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: presentation.expandedHeight)
            .animation(reducedMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: presentation.expandedWidth)
    }
}
