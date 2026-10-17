import Foundation

func runIslandPolicyTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) {
        if !condition { failures.append("Island interaction: " + label) }
    }
    // Retained files must not bypass the user's disabled-module preference.
    check(IslandInteractionPolicy.expandedTab(current: "music", preferShelf: true,
        shelfEnabled: false, shelfPriority: true, hasShelfItems: true) == "music", "disabled shelf stays disabled despite retained files")
    check(IslandInteractionPolicy.expandedTab(current: "music", preferShelf: true,
        shelfEnabled: true, shelfPriority: true, hasShelfItems: true) == "shelf", "enabled populated shelf keeps its priority")
    check(IslandInteractionPolicy.expandedTab(current: "mirror", preferShelf: true,
        shelfEnabled: true, shelfPriority: true, hasShelfItems: false) == "mirror", "empty shelf does not replace selected module")
    check(IslandInteractionPolicy.expandedTab(current: "music", preferShelf: true,
        shelfEnabled: true, shelfPriority: false, hasShelfItems: true) == "music", "disabled priority preserves selected module")
    check(IslandInteractionPolicy.expandedTab(current: "calendar", preferShelf: false,
        shelfEnabled: true, shelfPriority: true, hasShelfItems: true) == "calendar", "explicit expansion can bypass shelf priority")

    // Pointer leaves the island for a volume popover, dismisses it outside,
    // then re-enters: only the outside + dismissed state should collapse.
    check(!IslandInteractionPolicy.shouldCollapse(expanded: true, pointerInside: false,
        popoverOpen: true, shelfDragActive: false), "pointer may enter separate volume popover without collapsing")
    check(IslandInteractionPolicy.shouldCollapse(expanded: true, pointerInside: false,
        popoverOpen: false, shelfDragActive: false), "popover dismissal outside resumes collapse")
    check(!IslandInteractionPolicy.shouldCollapse(expanded: true, pointerInside: true,
        popoverOpen: false, shelfDragActive: false), "popover dismissal over island keeps it open")
    check(!IslandInteractionPolicy.shouldCollapse(expanded: true, pointerInside: false,
        popoverOpen: false, shelfDragActive: true), "drag source survives pointer exit during native drag")
    check(!IslandInteractionPolicy.shouldCollapse(expanded: false, pointerInside: false,
        popoverOpen: false, shelfDragActive: false), "closed island ignores stale collapse work")
    let lyricArea = CGRect(x: 100, y: 100, width: 200, height: 33)
    var hover = FloatingLyricsHoverState()
    check(hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 0), "entering floating lyrics hides them")
    check(hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 1), "removing the view/window hit area does not count as a pointer exit")
    check(hover.update(pointer: CGPoint(x: 302, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 2), "small edge jitter cannot flash the overlay back")
    check(hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 3), "leaving starts a short restore delay")
    check(hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 3.05), "reentry cancels a queued restore")
    check(hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 3.2), "leaving again starts a new delay")
    check(!hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 3.33), "moving away restores lyrics without any click")
    _ = hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: true, now: 4)
    check(hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: true, now: 5), "underlying drag keeps overlay out of the way")
    _ = hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 6)
    check(!hover.update(pointer: CGPoint(x: 400, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 6.13), "release outside restores lyrics after the delay")
    _ = hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 7)
    check(!hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: nil,
        mousePressed: false, now: 7.01), "stopping lyrics/expanding/removing a screen clears temporary hover state")
    var secondDisplay = FloatingLyricsHoverState()
    _ = hover.update(pointer: CGPoint(x: 150, y: 115), lyricRegion: lyricArea,
        mousePressed: false, now: 8)
    check(!secondDisplay.update(pointer: CGPoint(x: 150, y: 115),
        lyricRegion: lyricArea.offsetBy(dx: 1000, dy: 0), mousePressed: false, now: 8),
        "hover on one display does not hide another display's lyrics")
    return failures
}
